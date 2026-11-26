-- =============================================================================
-- API (funções RPC chamadas pelo app) e segurança por linha (RLS)
-- Cada usuário só enxerga e altera dados da própria oficina.
-- Agendamentos só são criados/alterados pelas funções, nunca por insert direto.
-- =============================================================================

-- Funções internas: ninguém executa por padrão; liberamos só as de leitura
-- que as políticas e views precisam.
revoke all on schema regras from public;
revoke execute on all functions in schema regras from public;
grant usage on schema regras to authenticated;
grant execute on function
  regras.ocupa_vaga(public.status_agendamento),
  regras.segura_box(public.status_agendamento),
  regras.minha_oficina(),
  regras.meu_perfil(),
  regras.calcular_fim(uuid, timestamptz, integer),
  regras.validar_janela(uuid, timestamptz, timestamptz),
  regras.boxes_livres(uuid, timestamptz, timestamptz, uuid)
to authenticated;

-- -----------------------------------------------------------------------------
-- Funções RPC
-- -----------------------------------------------------------------------------
create function public.exigir_perfil(variadic p_perfis public.perfil_usuario[])
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  v_oficina uuid := regras.minha_oficina();
begin
  if v_oficina is null then
    raise exception 'Usuário sem oficina vinculada.' using errcode = '42501';
  end if;
  if not (regras.meu_perfil() = any (p_perfis)) then
    raise exception 'Seu perfil não tem permissão para esta ação.' using errcode = '42501';
  end if;
  return v_oficina;
end $$;

-- Slots do dia com nº de vagas livres.
create function public.disponibilidade(p_data date, p_duracao_min integer)
returns table (inicio timestamptz, fim timestamptz, vagas_livres integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_oficina uuid := public.exigir_perfil('admin', 'atendente', 'mecanico');
begin
  return query select * from regras.disponibilidade(v_oficina, p_data, p_duracao_min);
end $$;

create function public.proximos_horarios(p_a_partir timestamptz, p_duracao_min integer, p_limite integer default 5)
returns table (inicio timestamptz, fim timestamptz, vagas_livres integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_oficina uuid := public.exigir_perfil('admin', 'atendente', 'mecanico');
begin
  return query select * from regras.proximos_horarios(v_oficina, p_a_partir, p_duracao_min, p_limite);
end $$;

create function public.criar_agendamento(
  p_cliente_id  uuid,
  p_veiculo_id  uuid,
  p_servicos    uuid[],
  p_inicio      timestamptz,
  p_observacoes text default null
)
returns public.agendamentos language plpgsql volatile security definer set search_path = public as $$
declare
  v_oficina uuid := public.exigir_perfil('admin', 'atendente');
begin
  return regras.criar_agendamento(v_oficina, p_cliente_id, p_veiculo_id, p_servicos,
                                  p_inicio, p_observacoes, auth.uid());
end $$;

create function public.mudar_status(
  p_agendamento_id uuid,
  p_status         public.status_agendamento,
  p_observacao     text default null
)
returns public.agendamentos language plpgsql volatile security definer set search_path = public as $$
declare
  v_oficina uuid;
begin
  -- Mecânico só movimenta o trabalho no box; o resto é com admin/atendente.
  if p_status in ('em_atendimento', 'aguardando_peca', 'concluido') then
    v_oficina := public.exigir_perfil('admin', 'atendente', 'mecanico');
  else
    v_oficina := public.exigir_perfil('admin', 'atendente');
  end if;
  return regras.mudar_status(v_oficina, p_agendamento_id, p_status, p_observacao);
end $$;

-- Primeiro acesso: usuário logado sem oficina cria a sua e vira admin.
create function public.registrar_oficina(p_nome_oficina text, p_seu_nome text)
returns public.oficinas language plpgsql volatile security definer set search_path = public as $$
declare
  v_of public.oficinas;
begin
  if auth.uid() is null then
    raise exception 'Faça login primeiro.' using errcode = '42501';
  end if;
  if exists (select 1 from public.perfis where id = auth.uid()) then
    raise exception 'Este usuário já pertence a uma oficina.' using errcode = 'OF003';
  end if;

  insert into public.oficinas (nome) values (p_nome_oficina) returning * into v_of;
  insert into public.perfis (id, oficina_id, nome, perfil) values (auth.uid(), v_of.id, p_seu_nome, 'admin');
  -- Padrão: seg a sex 8h-18h e sábado 8h-12h, almoço 12h-13h nos dias úteis.
  insert into public.horarios_funcionamento (oficina_id, dia_semana, abre, fecha, almoco_inicio, almoco_fim)
  select v_of.id, d, time '08:00', time '18:00', time '12:00', time '13:00' from generate_series(1, 5) d
  union all
  select v_of.id, 6, time '08:00', time '12:00', null, null;
  insert into public.boxes (oficina_id, nome, ordem)
  select v_of.id, 'Box ' || n, n from generate_series(1, 4) n;
  return v_of;
end $$;

revoke execute on function
  public.exigir_perfil(public.perfil_usuario[]),
  public.disponibilidade(date, integer),
  public.proximos_horarios(timestamptz, integer, integer),
  public.criar_agendamento(uuid, uuid, uuid[], timestamptz, text),
  public.mudar_status(uuid, public.status_agendamento, text),
  public.registrar_oficina(text, text)
from public, anon;
grant execute on function
  public.disponibilidade(date, integer),
  public.proximos_horarios(timestamptz, integer, integer),
  public.criar_agendamento(uuid, uuid, uuid[], timestamptz, text),
  public.mudar_status(uuid, public.status_agendamento, text),
  public.registrar_oficina(text, text)
to authenticated;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.oficinas               enable row level security;
alter table public.horarios_funcionamento enable row level security;
alter table public.perfis                 enable row level security;
alter table public.boxes                  enable row level security;
alter table public.clientes               enable row level security;
alter table public.veiculos               enable row level security;
alter table public.servicos               enable row level security;
alter table public.agendamentos           enable row level security;
alter table public.agendamento_servicos   enable row level security;
alter table public.historico_status       enable row level security;
alter table public.bloqueios              enable row level security;

grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;

-- Leitura: tudo da própria oficina.
create policy oficina_select on public.oficinas for select to authenticated
  using (id = regras.minha_oficina());
create policy oficina_update on public.oficinas for update to authenticated
  using (id = regras.minha_oficina() and regras.meu_perfil() = 'admin');

create policy perfis_select on public.perfis for select to authenticated
  using (oficina_id = regras.minha_oficina());
create policy perfis_admin on public.perfis for all to authenticated
  using (oficina_id = regras.minha_oficina() and regras.meu_perfil() = 'admin')
  with check (oficina_id = regras.minha_oficina() and regras.meu_perfil() = 'admin');

-- Configuração: todos leem, só admin altera.
do $$
declare t text;
begin
  foreach t in array array['horarios_funcionamento', 'boxes', 'bloqueios', 'servicos'] loop
    execute format(
      'create policy %1$s_select on public.%1$s for select to authenticated
         using (oficina_id = regras.minha_oficina())', t);
    execute format(
      'create policy %1$s_admin on public.%1$s for all to authenticated
         using (oficina_id = regras.minha_oficina() and regras.meu_perfil() = ''admin'')
         with check (oficina_id = regras.minha_oficina() and regras.meu_perfil() = ''admin'')', t);
  end loop;
end $$;

-- Clientes e veículos: admin e atendente cadastram e editam; só admin apaga.
do $$
declare t text;
begin
  foreach t in array array['clientes', 'veiculos'] loop
    execute format(
      'create policy %1$s_select on public.%1$s for select to authenticated
         using (oficina_id = regras.minha_oficina())', t);
    execute format(
      'create policy %1$s_insert on public.%1$s for insert to authenticated
         with check (oficina_id = regras.minha_oficina() and regras.meu_perfil() in (''admin'', ''atendente''))', t);
    execute format(
      'create policy %1$s_update on public.%1$s for update to authenticated
         using (oficina_id = regras.minha_oficina() and regras.meu_perfil() in (''admin'', ''atendente''))
         with check (oficina_id = regras.minha_oficina())', t);
    execute format(
      'create policy %1$s_delete on public.%1$s for delete to authenticated
         using (oficina_id = regras.minha_oficina() and regras.meu_perfil() = ''admin'')', t);
  end loop;
end $$;

-- Agendamentos: só leitura direta. Escrita apenas por criar_agendamento/mudar_status.
create policy agendamentos_select on public.agendamentos for select to authenticated
  using (oficina_id = regras.minha_oficina());

create policy agendamento_servicos_select on public.agendamento_servicos for select to authenticated
  using (exists (select 1 from public.agendamentos a
                  where a.id = agendamento_id and a.oficina_id = regras.minha_oficina()));

create policy historico_status_select on public.historico_status for select to authenticated
  using (exists (select 1 from public.agendamentos a
                  where a.id = agendamento_id and a.oficina_id = regras.minha_oficina()));

-- Preenche oficina_id automaticamente nos cadastros feitos pelo app.
alter table public.clientes               alter column oficina_id set default regras.minha_oficina();
alter table public.veiculos               alter column oficina_id set default regras.minha_oficina();
alter table public.servicos               alter column oficina_id set default regras.minha_oficina();
alter table public.boxes                  alter column oficina_id set default regras.minha_oficina();
alter table public.bloqueios              alter column oficina_id set default regras.minha_oficina();
alter table public.horarios_funcionamento alter column oficina_id set default regras.minha_oficina();
