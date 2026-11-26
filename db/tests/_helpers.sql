-- Utilitários de teste: asserções e uma oficina de exemplo.
create schema if not exists tests;

create or replace function tests.ok(p_cond boolean, p_nome text) returns void
language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FALHOU: %', p_nome;
  end if;
  raise notice 'ok - %', p_nome;
end $$;

-- Executa p_sql esperando erro com o SQLSTATE p_code. Devolve "mensagem | hint".
create or replace function tests.erro(p_sql text, p_code text, p_nome text) returns text
language plpgsql as $$
declare v_code text; v_msg text; v_hint text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text, v_hint = pg_exception_hint;
    if v_code = p_code then
      raise notice 'ok - % (% %)', p_nome, v_code, v_msg;
      return v_msg || ' | ' || coalesce(v_hint, '');
    end if;
    raise exception 'FALHOU: % (esperava %, veio %: %)', p_nome, p_code, v_code, v_msg;
  end;
  raise exception 'FALHOU: % (esperava erro %, mas passou)', p_nome, p_code;
end $$;

-- Horário local de São Paulo -> timestamptz
create or replace function tests.t(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Sao_Paulo' $$;

-- Oficina de teste: seg-sex 08-18 com almoço 12-13, sábado 08-12, 4 boxes,
-- 4 serviços, 1 cliente com 1 veículo.
create or replace function tests.criar_oficina(p_nome text default 'Oficina Teste') returns uuid
language plpgsql as $$
declare v uuid; c uuid;
begin
  insert into public.oficinas (nome) values (p_nome) returning id into v;
  insert into public.horarios_funcionamento (oficina_id, dia_semana, abre, fecha, almoco_inicio, almoco_fim)
  select v, d, '08:00', '18:00', '12:00', '13:00' from generate_series(1, 5) d;
  insert into public.horarios_funcionamento (oficina_id, dia_semana, abre, fecha) values (v, 6, '08:00', '12:00');
  insert into public.boxes (oficina_id, nome, ordem) select v, 'Box ' || n, n from generate_series(1, 4) n;
  insert into public.servicos (oficina_id, nome, duracao_estimada_min, preco_base) values
    (v, 'Troca de óleo', 30, 150), (v, 'Alinhamento', 60, 120),
    (v, 'Freios', 120, 300), (v, 'Revisão', 180, 600);
  insert into public.clientes (oficina_id, nome, telefone) values (v, 'Cliente Teste', '(11) 99999-0000')
  returning id into c;
  insert into public.veiculos (oficina_id, cliente_id, placa, modelo) values (v, c, 'abc-1d23', 'Gol');
  return v;
end $$;

create or replace function tests.servico(p_oficina uuid, p_nome text) returns uuid
language sql stable as $$ select id from public.servicos where oficina_id = p_oficina and nome = p_nome $$;

-- Agenda pelo caminho oficial (regras.criar_agendamento) com o cliente/veículo de teste.
create or replace function tests.agendar(p_oficina uuid, p_inicio_local text, p_servicos text[])
returns public.agendamentos language plpgsql as $$
declare c uuid; v uuid;
begin
  select id into c from public.clientes where oficina_id = p_oficina limit 1;
  select id into v from public.veiculos where cliente_id = c limit 1;
  return regras.criar_agendamento(
    p_oficina, c, v,
    (select array_agg(tests.servico(p_oficina, s)) from unnest(p_servicos) s),
    tests.t(p_inicio_local), null, null);
end $$;

create or replace function tests.box_nome(p_box uuid) returns text
language sql stable as $$ select nome from public.boxes where id = p_box $$;
