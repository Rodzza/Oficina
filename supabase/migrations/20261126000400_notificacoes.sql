-- =============================================================================
-- Aviso de "carro pronto" no WhatsApp do cliente
--
-- Quando o agendamento muda para "concluido", o banco grava uma notificação
-- pendente nesta fila (padrão outbox). Quem envia é uma Edge Function do
-- Supabase usando a API oficial do WhatsApp (Cloud API da Meta). Se o envio
-- automático não estiver configurado ou falhar, o app mostra um botão que abre
-- o WhatsApp com a mensagem pronta (wa.me), e a atendente marca como enviada.
-- =============================================================================

create type public.status_notificacao as enum ('pendente', 'enviando', 'enviada', 'falhou', 'enviada_manual', 'cancelada');

create table public.notificacoes (
  id                   uuid primary key default gen_random_uuid(),
  oficina_id           uuid not null references public.oficinas (id) on delete cascade,
  agendamento_id       uuid not null references public.agendamentos (id) on delete cascade,
  cliente_id           uuid not null references public.clientes (id) on delete cascade,
  tipo                 text not null default 'carro_pronto',
  telefone             text not null,          -- formato internacional só com dígitos, ex.: 5511987650001
  mensagem             text not null,          -- texto pronto (usado no wa.me e de referência)
  parametros           jsonb not null default '{}'::jsonb, -- variáveis do template aprovado na Meta
  status               public.status_notificacao not null default 'pendente',
  tentativas           integer not null default 0,
  erro                 text,
  id_mensagem_whatsapp text,                   -- id devolvido pela Meta
  criado_em            timestamptz not null default now(),
  enviada_em           timestamptz,
  enviada_por          uuid references auth.users (id) on delete set null,
  unique (agendamento_id, tipo)
);
create index notificacoes_pendentes_idx on public.notificacoes (status, criado_em) where status in ('pendente', 'falhou');
create index notificacoes_oficina_idx on public.notificacoes (oficina_id, criado_em desc);

-- Permite desligar o aviso por oficina (ligado por padrão).
alter table public.oficinas add column avisar_carro_pronto boolean not null default true;

-- Telefone brasileiro -> formato internacional (55 + DDD + número).
create function regras.telefone_internacional(p_telefone text)
returns text language sql immutable as $$
  select case
    when length(d) in (10, 11) then '55' || d
    else d
  end
  from (select regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g') as d) x
$$;

create function regras.tg_notificar_carro_pronto() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_cli  public.clientes;
  v_vei  public.veiculos;
  v_of   public.oficinas;
  v_primeiro_nome text;
  v_carro text;
begin
  if new.status <> 'concluido' or old.status = 'concluido' then
    return null;
  end if;

  select * into v_of  from public.oficinas where id = new.oficina_id;
  if not v_of.avisar_carro_pronto then
    return null;
  end if;
  select * into v_cli from public.clientes where id = new.cliente_id;
  select * into v_vei from public.veiculos where id = new.veiculo_id;

  v_primeiro_nome := split_part(trim(v_cli.nome), ' ', 1);
  v_carro := trim(coalesce(v_vei.modelo, 'carro') || ' placa ' || v_vei.placa);

  insert into public.notificacoes (oficina_id, agendamento_id, cliente_id, telefone, mensagem, parametros)
  values (
    new.oficina_id, new.id, new.cliente_id,
    regras.telefone_internacional(v_cli.telefone),
    format('Olá, %s! Seu %s está pronto e já pode ser retirado na %s.%s',
           v_primeiro_nome, v_carro, v_of.nome,
           case when v_of.telefone is not null then ' Dúvidas: ' || v_of.telefone else '' end),
    jsonb_build_object('nome', v_primeiro_nome, 'carro', v_carro, 'oficina', v_of.nome)
  )
  on conflict (agendamento_id, tipo) do nothing;

  return null;
end $$;

create trigger agendamentos_notificar_carro_pronto
  after update of status on public.agendamentos
  for each row execute function regras.tg_notificar_carro_pronto();

-- A Edge Function (service_role) pega as pendentes com esta função, sem
-- risco de duas execuções enviarem a mesma mensagem.
create function public.pegar_notificacoes_pendentes(p_limite integer default 20)
returns setof public.notificacoes language sql volatile security definer set search_path = public as $$
  update public.notificacoes n
     set status = 'enviando', tentativas = n.tentativas + 1
   where n.id in (
     select id from public.notificacoes
      where status = 'pendente' or (status = 'falhou' and tentativas < 3)
      order by criado_em
      limit p_limite
      for update skip locked
   )
  returning n.*
$$;
revoke execute on function public.pegar_notificacoes_pendentes(integer) from public, anon, authenticated;
grant execute on function public.pegar_notificacoes_pendentes(integer) to service_role;

-- Envio manual pelo app (botão "Abrir WhatsApp"): marca como enviada.
create function public.marcar_notificacao_enviada(p_notificacao_id uuid)
returns public.notificacoes language plpgsql volatile security definer set search_path = public as $$
declare
  v_oficina uuid := public.exigir_perfil('admin', 'atendente', 'mecanico');
  v public.notificacoes;
begin
  update public.notificacoes
     set status = 'enviada_manual', enviada_em = now(), enviada_por = auth.uid()
   where id = p_notificacao_id and oficina_id = v_oficina and status <> 'enviada'
  returning * into v;
  if not found then
    raise exception 'Notificação não encontrada.' using errcode = 'OF003';
  end if;
  return v;
end $$;
revoke execute on function public.marcar_notificacao_enviada(uuid) from public, anon;
grant execute on function public.marcar_notificacao_enviada(uuid) to authenticated;

alter table public.notificacoes enable row level security;
grant select on public.notificacoes to authenticated;
revoke insert, update, delete on public.notificacoes from authenticated;
grant select, insert, update, delete on public.notificacoes to service_role;
create policy notificacoes_select on public.notificacoes for select to authenticated
  using (oficina_id = regras.minha_oficina());
