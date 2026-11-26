-- =============================================================================
-- Regras de capacidade e agenda
--
-- Schema "regras": funções internas, puras de lógica, que recebem a oficina
-- como parâmetro. Não ficam expostas na API (o Supabase só expõe "public").
-- Schema "public": funções RPC chamadas pelo app; descobrem a oficina pelo
-- usuário logado e checam o perfil antes de chamar as internas.
--
-- Códigos de erro próprios (aparecem em error.code no supabase-js):
--   OF001  horário inválido (fora do expediente, almoço, bloqueio, passado)
--   OF002  sem box livre no intervalo inteiro
--   OF003  dados inválidos (cliente/veículo/serviço)
--   OF004  mudança de status não permitida
--   42501  sem permissão
-- Em OF001/OF002, "hint" traz os próximos horários em texto e "detail" em JSON.
-- =============================================================================

create schema if not exists regras;

-- Status que ocupam vaga (todos menos cancelado, não compareceu e entregue).
create function regras.ocupa_vaga(p_status public.status_agendamento)
returns boolean language sql immutable as $$
  select p_status not in ('cancelado', 'nao_compareceu', 'entregue')
$$;

-- Status em que o carro segura o box mesmo depois do fim previsto (regra 6).
create function regras.segura_box(p_status public.status_agendamento)
returns boolean language sql immutable as $$
  select p_status in ('em_atendimento', 'aguardando_peca')
$$;

-- -----------------------------------------------------------------------------
-- Usuário logado
-- -----------------------------------------------------------------------------
create function regras.minha_oficina()
returns uuid language sql stable security definer set search_path = public as $$
  select oficina_id from public.perfis where id = auth.uid()
$$;

create function regras.meu_perfil()
returns public.perfil_usuario language sql stable security definer set search_path = public as $$
  select perfil from public.perfis where id = auth.uid()
$$;

-- -----------------------------------------------------------------------------
-- Cálculo do fim: soma das durações. Se o serviço atravessa o almoço,
-- o trabalho pausa e o fim é empurrado pela duração do almoço
-- (o box continua ocupado durante o almoço).
-- -----------------------------------------------------------------------------
create function regras.calcular_fim(p_oficina uuid, p_inicio timestamptz, p_duracao_min integer)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_fuso      text;
  v_local     timestamp;
  v_fim_local timestamp;
  h           public.horarios_funcionamento;
begin
  select fuso into v_fuso from public.oficinas where id = p_oficina;
  v_local := p_inicio at time zone v_fuso;
  v_fim_local := v_local + make_interval(mins => p_duracao_min);

  select * into h from public.horarios_funcionamento
   where oficina_id = p_oficina and dia_semana = extract(dow from v_local);

  if found and h.almoco_inicio is not null
     and v_local < v_local::date + h.almoco_inicio
     and v_fim_local > v_local::date + h.almoco_inicio then
    v_fim_local := v_fim_local + (h.almoco_fim - h.almoco_inicio);
  end if;

  return v_fim_local at time zone v_fuso;
end $$;

-- -----------------------------------------------------------------------------
-- Regra 5: janela dentro do expediente, sem começar no almoço e fora de
-- bloqueios da oficina inteira. Retorna null se ok, ou a mensagem do problema.
-- (Bloqueio de um box só é tratado em boxes_livres.)
-- -----------------------------------------------------------------------------
create function regras.validar_janela(p_oficina uuid, p_inicio timestamptz, p_fim timestamptz)
returns text language plpgsql stable set search_path = public as $$
declare
  v_fuso      text;
  v_ini       timestamp;
  v_fim       timestamp;
  h           public.horarios_funcionamento;
  v_motivo    text;
begin
  select fuso into v_fuso from public.oficinas where id = p_oficina;
  v_ini := p_inicio at time zone v_fuso;
  v_fim := p_fim at time zone v_fuso;

  select * into h from public.horarios_funcionamento
   where oficina_id = p_oficina and dia_semana = extract(dow from v_ini);
  if not found then
    return 'A oficina não abre neste dia.';
  end if;

  if v_ini < v_ini::date + h.abre or v_fim > v_ini::date + h.fecha then
    return format('Fora do horário de funcionamento (%s às %s).',
                  to_char(h.abre, 'HH24:MI'), to_char(h.fecha, 'HH24:MI'));
  end if;

  if h.almoco_inicio is not null
     and v_ini >= v_ini::date + h.almoco_inicio
     and v_ini <  v_ini::date + h.almoco_fim then
    return format('Horário de almoço (%s às %s).',
                  to_char(h.almoco_inicio, 'HH24:MI'), to_char(h.almoco_fim, 'HH24:MI'));
  end if;

  select motivo into v_motivo from public.bloqueios
   where oficina_id = p_oficina and box_id is null
     and inicio < p_fim and fim > p_inicio
   order by inicio limit 1;
  if found then
    return format('A oficina está bloqueada neste período: %s.', v_motivo);
  end if;

  return null;
end $$;

-- -----------------------------------------------------------------------------
-- Regras 1, 2, 3 e 6: boxes ativos livres durante TODO o intervalo.
-- Um box está ocupado se tem agendamento que ocupa vaga e se sobrepõe
-- (novo.inicio < existente.fim AND novo.fim > existente.inicio), ou se tem um
-- carro em atendimento / aguardando peça que começou antes do fim pedido
-- (esse carro segura o box até mudar de status), ou bloqueio do box.
-- p_ignorar: agendamento a desconsiderar (usado ao realocar).
-- -----------------------------------------------------------------------------
create function regras.boxes_livres(
  p_oficina uuid, p_inicio timestamptz, p_fim timestamptz, p_ignorar uuid default null
)
returns setof public.boxes language sql stable set search_path = public as $$
  select b.*
    from public.boxes b
   where b.oficina_id = p_oficina
     and b.ativo
     and not exists (
       select 1 from public.agendamentos a
        where a.box_id = b.id
          and a.id is distinct from p_ignorar
          and regras.ocupa_vaga(a.status)
          and a.inicio < p_fim
          and (a.fim > p_inicio or regras.segura_box(a.status))
     )
     and not exists (
       select 1 from public.bloqueios bl
        where bl.box_id = b.id
          and bl.inicio < p_fim and bl.fim > p_inicio
     )
   order by b.ordem, b.nome
$$;

-- -----------------------------------------------------------------------------
-- disponibilidade(data, duração) -> slots válidos do dia com nº de vagas livres.
-- Inclui slots com 0 vagas (a tela mostra como "lotado"). Ignora horários
-- que já passaram.
-- -----------------------------------------------------------------------------
create function regras.disponibilidade(p_oficina uuid, p_data date, p_duracao_min integer)
returns table (inicio timestamptz, fim timestamptz, vagas_livres integer)
language plpgsql stable set search_path = public as $$
declare
  v_fuso  text;
  v_slot  integer;
  h       public.horarios_funcionamento;
  v_t     timestamp;
begin
  if p_duracao_min is null or p_duracao_min <= 0 then
    raise exception 'Duração inválida.' using errcode = 'OF003';
  end if;

  select o.fuso, o.duracao_slot_min into v_fuso, v_slot from public.oficinas o where o.id = p_oficina;
  select * into h from public.horarios_funcionamento hf
   where hf.oficina_id = p_oficina and hf.dia_semana = extract(dow from p_data);
  if not found then
    return;
  end if;

  v_t := p_data + h.abre;
  while v_t < p_data + h.fecha loop
    inicio := v_t at time zone v_fuso;
    fim := regras.calcular_fim(p_oficina, inicio, p_duracao_min);
    if inicio >= now() and regras.validar_janela(p_oficina, inicio, fim) is null then
      select count(*)::int into vagas_livres from regras.boxes_livres(p_oficina, inicio, fim);
      return next;
    end if;
    v_t := v_t + make_interval(mins => v_slot);
  end loop;
end $$;

-- Próximos horários com vaga a partir de um instante (procura até 14 dias).
create function regras.proximos_horarios(
  p_oficina uuid, p_a_partir timestamptz, p_duracao_min integer, p_limite integer default 5
)
returns table (inicio timestamptz, fim timestamptz, vagas_livres integer)
language plpgsql stable set search_path = public as $$
declare
  v_fuso  text;
  v_dia   date;
  v_achados integer := 0;
  r       record;
begin
  select fuso into v_fuso from public.oficinas where id = p_oficina;
  v_dia := (greatest(p_a_partir, now()) at time zone v_fuso)::date;

  for i in 0..13 loop
    for r in select * from regras.disponibilidade(p_oficina, v_dia + i, p_duracao_min) d
              where d.inicio >= p_a_partir and d.vagas_livres > 0
              order by d.inicio loop
      inicio := r.inicio; fim := r.fim; vagas_livres := r.vagas_livres;
      return next;
      v_achados := v_achados + 1;
      if v_achados >= p_limite then
        return;
      end if;
    end loop;
  end loop;
end $$;

-- Formata sugestões para mensagem de erro: (texto para hint, json para detail).
create function regras.sugestoes(p_oficina uuid, p_a_partir timestamptz, p_duracao_min integer)
returns table (texto text, dados jsonb)
language sql stable set search_path = public as $$
  with s as (
    select p.inicio, p.fim, p.vagas_livres, o.fuso
      from regras.proximos_horarios(p_oficina, p_a_partir, p_duracao_min, 5) p
      cross join public.oficinas o
     where o.id = p_oficina
  )
  select
    coalesce('Próximos horários disponíveis: '
             || string_agg(to_char(s.inicio at time zone s.fuso, 'DD/MM HH24:MI'), ', ' order by s.inicio),
             'Nenhum horário disponível nos próximos 14 dias.'),
    coalesce(jsonb_agg(jsonb_build_object('inicio', s.inicio, 'fim', s.fim, 'vagas_livres', s.vagas_livres)
                       order by s.inicio), '[]'::jsonb)
  from s
$$;

-- -----------------------------------------------------------------------------
-- Criar agendamento (regras 1 a 5).
-- Um lock por oficina serializa as reservas: duas atendentes clicando ao mesmo
-- tempo são atendidas uma depois da outra, e a segunda recebe outro box ou a
-- recusa. A constraint de exclusão da tabela é a segunda linha de defesa.
-- -----------------------------------------------------------------------------
create function regras.criar_agendamento(
  p_oficina     uuid,
  p_cliente_id  uuid,
  p_veiculo_id  uuid,
  p_servicos    uuid[],
  p_inicio      timestamptz,
  p_observacoes text,
  p_criado_por  uuid
)
returns public.agendamentos language plpgsql volatile set search_path = public as $$
declare
  v_qtd_pedida  integer;
  v_qtd_ok      integer;
  v_duracao     integer;
  v_fim         timestamptz;
  v_erro        text;
  v_box         uuid;
  v_sug         record;
  v_ag          public.agendamentos;
begin
  perform pg_advisory_xact_lock(hashtextextended('agenda:' || p_oficina::text, 0));

  if not exists (select 1 from public.clientes where id = p_cliente_id and oficina_id = p_oficina) then
    raise exception 'Cliente não encontrado.' using errcode = 'OF003';
  end if;
  if not exists (select 1 from public.veiculos
                  where id = p_veiculo_id and oficina_id = p_oficina and cliente_id = p_cliente_id) then
    raise exception 'Veículo não encontrado para este cliente.' using errcode = 'OF003';
  end if;

  select count(distinct x) into v_qtd_pedida from unnest(p_servicos) x;
  if coalesce(v_qtd_pedida, 0) = 0 then
    raise exception 'Escolha pelo menos um serviço.' using errcode = 'OF003';
  end if;
  select count(*), sum(duracao_estimada_min) into v_qtd_ok, v_duracao
    from public.servicos
   where id = any (p_servicos) and oficina_id = p_oficina and ativo;
  if v_qtd_ok <> v_qtd_pedida then
    raise exception 'Serviço inválido ou inativo.' using errcode = 'OF003';
  end if;

  v_fim := regras.calcular_fim(p_oficina, p_inicio, v_duracao);

  if p_inicio < now() then
    v_erro := 'Não é possível agendar em um horário que já passou.';
  else
    v_erro := regras.validar_janela(p_oficina, p_inicio, v_fim);
  end if;
  if v_erro is not null then
    select * into v_sug from regras.sugestoes(p_oficina, p_inicio, v_duracao);
    raise exception '%', v_erro
      using errcode = 'OF001', hint = v_sug.texto, detail = v_sug.dados::text;
  end if;

  select id into v_box from regras.boxes_livres(p_oficina, p_inicio, v_fim) limit 1;
  if v_box is null then
    select * into v_sug from regras.sugestoes(p_oficina, p_inicio, v_duracao);
    raise exception 'Não há box livre durante todo o horário escolhido.'
      using errcode = 'OF002', hint = v_sug.texto, detail = v_sug.dados::text;
  end if;

  insert into public.agendamentos
         (oficina_id, cliente_id, veiculo_id, box_id, inicio, fim, observacoes, criado_por)
  values (p_oficina, p_cliente_id, p_veiculo_id, v_box, p_inicio, v_fim, p_observacoes, p_criado_por)
  returning * into v_ag;

  insert into public.agendamento_servicos (agendamento_id, servico_id, duracao_min, preco)
  select v_ag.id, s.id, s.duracao_estimada_min, s.preco_base
    from public.servicos s
   where s.id = any (p_servicos) and s.oficina_id = p_oficina;

  return v_ag;
end $$;

-- -----------------------------------------------------------------------------
-- Regras 6 e 8: agendamentos futuros que perderam o box (box desativado,
-- bloqueado, ou ocupado por um carro que passou do horário) tentam ir para
-- outro box livre. O que não couber continua lá e aparece em
-- agendamentos_em_conflito. Nada é apagado.
-- -----------------------------------------------------------------------------
create function regras.realocar_conflitos(p_oficina uuid)
returns integer language plpgsql volatile set search_path = public as $$
declare
  r        record;
  v_box    uuid;
  v_movidos integer := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended('agenda:' || p_oficina::text, 0));

  for r in
    select a.* from public.agendamentos a
     where a.oficina_id = p_oficina
       and a.status in ('agendado', 'confirmado')
       and a.fim > now()
       and not exists (select 1 from regras.boxes_livres(p_oficina, a.inicio, a.fim, a.id) b
                        where b.id = a.box_id)
     order by a.inicio
  loop
    select id into v_box from regras.boxes_livres(p_oficina, r.inicio, r.fim, r.id) limit 1;
    if v_box is not null then
      update public.agendamentos set box_id = v_box where id = r.id;
      v_movidos := v_movidos + 1;
    end if;
  end loop;

  return v_movidos;
end $$;

-- -----------------------------------------------------------------------------
-- Mudança de status com validação de transição.
-- -----------------------------------------------------------------------------
create function regras.transicao_permitida(
  p_de public.status_agendamento, p_para public.status_agendamento
)
returns boolean language sql immutable as $$
  select case p_de
    when 'agendado'        then p_para in ('confirmado', 'em_atendimento', 'cancelado', 'nao_compareceu')
    when 'confirmado'      then p_para in ('em_atendimento', 'cancelado', 'nao_compareceu')
    when 'em_atendimento'  then p_para in ('aguardando_peca', 'concluido')
    when 'aguardando_peca' then p_para in ('em_atendimento', 'concluido')
    when 'concluido'       then p_para in ('entregue')
    else false
  end
$$;

create function regras.mudar_status(
  p_oficina uuid, p_agendamento uuid, p_status public.status_agendamento, p_observacao text
)
returns public.agendamentos language plpgsql volatile set search_path = public as $$
declare
  v_ag public.agendamentos;
begin
  perform pg_advisory_xact_lock(hashtextextended('agenda:' || p_oficina::text, 0));

  select * into v_ag from public.agendamentos
   where id = p_agendamento and oficina_id = p_oficina
   for update;
  if not found then
    raise exception 'Agendamento não encontrado.' using errcode = 'OF003';
  end if;

  if not regras.transicao_permitida(v_ag.status, p_status) then
    raise exception 'Não é possível mudar de "%" para "%".', v_ag.status, p_status
      using errcode = 'OF004';
  end if;

  perform set_config('oficina.obs_status', coalesce(p_observacao, ''), true);
  update public.agendamentos set status = p_status where id = p_agendamento
  returning * into v_ag;
  perform set_config('oficina.obs_status', '', true);

  -- Carro que segura o box pode empurrar os próximos agendamentos daquele box.
  if regras.segura_box(p_status) then
    perform regras.realocar_conflitos(p_oficina);
  end if;

  return v_ag;
end $$;

-- Gatilhos da regra 8: desativar box ou criar bloqueio tenta realocar.
create function regras.tg_realocar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform regras.realocar_conflitos(new.oficina_id);
  return null;
end $$;

create trigger boxes_realocar_ao_desativar
  after update of ativo on public.boxes
  for each row when (old.ativo and not new.ativo)
  execute function regras.tg_realocar();

create trigger bloqueios_realocar
  after insert or update on public.bloqueios
  for each row execute function regras.tg_realocar();

-- -----------------------------------------------------------------------------
-- Regra 8: agendamentos futuros em conflito (não cabem mais onde estão).
-- -----------------------------------------------------------------------------
create view public.agendamentos_em_conflito
with (security_invoker = true) as
select a.id as agendamento_id,
       a.oficina_id,
       a.box_id,
       a.inicio,
       a.fim,
       a.status,
       coalesce(
         regras.validar_janela(a.oficina_id, a.inicio, a.fim),
         case
           when not b.ativo then 'O box foi desativado e não há outro livre.'
           when exists (select 1 from public.bloqueios bl
                         where bl.box_id = a.box_id and bl.inicio < a.fim and bl.fim > a.inicio)
             then 'O box está bloqueado e não há outro livre.'
           else 'O box está ocupado por um carro que passou do horário e não há outro livre.'
         end
       ) as motivo
  from public.agendamentos a
  join public.boxes b on b.id = a.box_id
 where a.status in ('agendado', 'confirmado')
   and a.fim > now()
   and (
     regras.validar_janela(a.oficina_id, a.inicio, a.fim) is not null
     or not exists (select 1 from regras.boxes_livres(a.oficina_id, a.inicio, a.fim, a.id) l
                     where l.id = a.box_id)
   );

-- Painel "Pátio agora": carros que estão ocupando box neste momento.
create view public.patio_agora
with (security_invoker = true) as
select a.id as agendamento_id,
       a.oficina_id,
       a.box_id,
       b.nome as box_nome,
       a.status,
       a.inicio,
       a.fim,
       v.placa,
       v.modelo,
       c.nome as cliente_nome,
       (select max(h.alterado_em) from public.historico_status h
         where h.agendamento_id = a.id and h.status_novo = 'em_atendimento') as em_atendimento_desde,
       a.fim < now() as atrasado
  from public.agendamentos a
  join public.boxes b    on b.id = a.box_id
  join public.veiculos v on v.id = a.veiculo_id
  join public.clientes c on c.id = a.cliente_id
 where a.status in ('em_atendimento', 'aguardando_peca', 'concluido')
    or (a.status in ('agendado', 'confirmado') and a.inicio <= now() and a.fim > now());
