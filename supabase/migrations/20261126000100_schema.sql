-- =============================================================================
-- Oficina: esquema base
-- Toda tabela de negócio carrega oficina_id (preparação para multi-oficina / SaaS).
-- FKs compostas (id, oficina_id) impedem misturar dados de oficinas diferentes.
-- =============================================================================

create extension if not exists btree_gist;

create type public.perfil_usuario as enum ('admin', 'atendente', 'mecanico');

create type public.status_agendamento as enum (
  'agendado',
  'confirmado',
  'em_atendimento',
  'aguardando_peca',
  'concluido',
  'entregue',
  'cancelado',
  'nao_compareceu'
);

-- -----------------------------------------------------------------------------
-- Oficina (configuração)
-- A capacidade efetiva é o número de boxes ativos (não existe um campo de
-- capacidade separado, para não haver duas fontes de verdade).
-- -----------------------------------------------------------------------------
create table public.oficinas (
  id                uuid primary key default gen_random_uuid(),
  nome              text not null,
  telefone          text,
  endereco          text,
  duracao_slot_min  integer not null default 30 check (duracao_slot_min between 5 and 240),
  fuso              text not null default 'America/Sao_Paulo',
  criado_em         timestamptz not null default now()
);

-- Horário de funcionamento por dia da semana. Sem linha para o dia = fechado.
create table public.horarios_funcionamento (
  id             uuid primary key default gen_random_uuid(),
  oficina_id     uuid not null references public.oficinas (id) on delete cascade,
  dia_semana     smallint not null check (dia_semana between 0 and 6), -- 0 = domingo
  abre           time not null,
  fecha          time not null,
  almoco_inicio  time,
  almoco_fim     time,
  unique (oficina_id, dia_semana),
  check (abre < fecha),
  check ((almoco_inicio is null) = (almoco_fim is null)),
  check (almoco_inicio is null
         or (abre < almoco_inicio and almoco_inicio < almoco_fim and almoco_fim < fecha))
);

-- Usuários (auth.users do Supabase) vinculados a uma oficina com um perfil.
create table public.perfis (
  id          uuid primary key references auth.users (id) on delete cascade,
  oficina_id  uuid not null references public.oficinas (id) on delete cascade,
  nome        text not null,
  perfil      public.perfil_usuario not null default 'atendente',
  criado_em   timestamptz not null default now()
);
create index perfis_oficina_idx on public.perfis (oficina_id);

-- Box (vaga física)
create table public.boxes (
  id          uuid primary key default gen_random_uuid(),
  oficina_id  uuid not null references public.oficinas (id) on delete cascade,
  nome        text not null,
  ordem       integer not null default 0,
  ativo       boolean not null default true,
  unique (oficina_id, nome),
  unique (id, oficina_id)
);

-- -----------------------------------------------------------------------------
-- Clientes, veículos e catálogo de serviços
-- -----------------------------------------------------------------------------
create table public.clientes (
  id           uuid primary key default gen_random_uuid(),
  oficina_id   uuid not null references public.oficinas (id) on delete cascade,
  nome         text not null,
  telefone     text not null,            -- WhatsApp, só dígitos (normalizado por trigger)
  email        text,
  observacoes  text,
  criado_em    timestamptz not null default now(),
  unique (id, oficina_id)
);
create index clientes_telefone_idx on public.clientes (oficina_id, telefone);
create index clientes_nome_idx on public.clientes (oficina_id, lower(nome));

create table public.veiculos (
  id          uuid primary key default gen_random_uuid(),
  oficina_id  uuid not null references public.oficinas (id) on delete cascade,
  cliente_id  uuid not null,
  placa       text not null,              -- maiúsculas, sem hífen (normalizado por trigger)
  marca       text,
  modelo      text,
  ano         smallint check (ano between 1900 and 2100),
  cor         text,
  km          integer check (km >= 0),
  criado_em   timestamptz not null default now(),
  unique (oficina_id, placa),
  unique (id, oficina_id),
  check (placa ~ '^[A-Z0-9]{7}$'),
  foreign key (cliente_id, oficina_id) references public.clientes (id, oficina_id) on delete restrict
);
create index veiculos_cliente_idx on public.veiculos (cliente_id);

create table public.servicos (
  id                    uuid primary key default gen_random_uuid(),
  oficina_id            uuid not null references public.oficinas (id) on delete cascade,
  nome                  text not null,
  descricao             text,
  duracao_estimada_min  integer not null check (duracao_estimada_min between 5 and 1440),
  preco_base            numeric(10, 2) not null default 0 check (preco_base >= 0),
  ativo                 boolean not null default true,
  unique (oficina_id, nome)
);

-- -----------------------------------------------------------------------------
-- Agendamentos
-- -----------------------------------------------------------------------------
create table public.agendamentos (
  id             uuid primary key default gen_random_uuid(),
  oficina_id     uuid not null references public.oficinas (id) on delete cascade,
  cliente_id     uuid not null,
  veiculo_id     uuid not null,
  box_id         uuid not null,
  inicio         timestamptz not null,
  fim            timestamptz not null,
  status         public.status_agendamento not null default 'agendado',
  observacoes    text,
  criado_por     uuid references auth.users (id) on delete set null,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  check (fim > inicio),
  foreign key (cliente_id, oficina_id) references public.clientes (id, oficina_id) on delete restrict,
  foreign key (veiculo_id, oficina_id) references public.veiculos (id, oficina_id) on delete restrict,
  foreign key (box_id, oficina_id) references public.boxes (id, oficina_id) on delete restrict,
  -- Regra 1/3/4: dois agendamentos que ocupam vaga nunca se sobrepõem no mesmo box.
  -- Garantido pelo próprio Postgres, mesmo com duas reservas simultâneas.
  -- Intervalo [inicio, fim): um termina 10:00 e outro começa 10:00 é permitido.
  constraint agendamentos_sem_sobreposicao_no_box exclude using gist (
    box_id with =,
    tstzrange(inicio, fim, '[)') with &&
  ) where (status not in ('cancelado', 'nao_compareceu', 'entregue'))
);
create index agendamentos_oficina_inicio_idx on public.agendamentos (oficina_id, inicio);
create index agendamentos_veiculo_idx on public.agendamentos (veiculo_id);

-- Serviços do agendamento, com duração e preço congelados no momento da reserva.
create table public.agendamento_servicos (
  agendamento_id  uuid not null references public.agendamentos (id) on delete cascade,
  servico_id      uuid not null references public.servicos (id) on delete restrict,
  duracao_min     integer not null,
  preco           numeric(10, 2) not null,
  primary key (agendamento_id, servico_id)
);

-- Histórico de status (quem e quando)
create table public.historico_status (
  id               bigint generated always as identity primary key,
  agendamento_id   uuid not null references public.agendamentos (id) on delete cascade,
  status_anterior  public.status_agendamento,
  status_novo      public.status_agendamento not null,
  alterado_por     uuid references auth.users (id) on delete set null,
  alterado_em      timestamptz not null default now(),
  observacao       text
);
create index historico_status_agendamento_idx on public.historico_status (agendamento_id, alterado_em);

-- Bloqueios: box_id nulo = oficina inteira (feriado); preenchido = só aquele box.
create table public.bloqueios (
  id          uuid primary key default gen_random_uuid(),
  oficina_id  uuid not null references public.oficinas (id) on delete cascade,
  box_id      uuid,
  inicio      timestamptz not null,
  fim         timestamptz not null,
  motivo      text not null,
  check (fim > inicio),
  foreign key (box_id, oficina_id) references public.boxes (id, oficina_id) on delete cascade
);
create index bloqueios_oficina_idx on public.bloqueios (oficina_id, inicio);

-- -----------------------------------------------------------------------------
-- Triggers utilitários
-- -----------------------------------------------------------------------------
create function public.tg_normalizar_placa() returns trigger
language plpgsql as $$
begin
  new.placa := upper(regexp_replace(new.placa, '[^A-Za-z0-9]', '', 'g'));
  return new;
end $$;

create trigger veiculos_normalizar_placa
  before insert or update of placa on public.veiculos
  for each row execute function public.tg_normalizar_placa();

create function public.tg_normalizar_telefone() returns trigger
language plpgsql as $$
begin
  new.telefone := regexp_replace(new.telefone, '\D', '', 'g');
  return new;
end $$;

create trigger clientes_normalizar_telefone
  before insert or update of telefone on public.clientes
  for each row execute function public.tg_normalizar_telefone();

create function public.tg_atualizado_em() returns trigger
language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

create trigger agendamentos_atualizado_em
  before update on public.agendamentos
  for each row execute function public.tg_atualizado_em();

-- Registra no histórico cada criação e cada mudança de status.
-- A observação opcional vem de mudar_status() via set_config('oficina.obs_status').
create function public.tg_historico_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.historico_status (agendamento_id, status_anterior, status_novo, alterado_por, observacao)
    values (
      new.id,
      case when tg_op = 'UPDATE' then old.status end,
      new.status,
      auth.uid(),
      nullif(current_setting('oficina.obs_status', true), '')
    );
  end if;
  return new;
end $$;

create trigger agendamentos_historico_status
  after insert or update of status on public.agendamentos
  for each row execute function public.tg_historico_status();
