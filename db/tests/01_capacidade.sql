-- Regras 1 a 4: capacidade, alocação automática, sobreposição e borda exata.
-- Data de teste: segunda-feira 04/03/2030 (horário de São Paulo).
begin;

-- Regra 1 e 2: capacidade cheia
do $$
declare o uuid := tests.criar_oficina(); a public.agendamentos; boxes text[] := '{}'; msg text;
begin
  for i in 1..4 loop
    a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
    boxes := boxes || tests.box_nome(a.box_id);
  end loop;
  perform tests.ok(boxes = array['Box 1', 'Box 2', 'Box 3', 'Box 4'],
    'capacidade: 4 carros no mesmo horário vão para os 4 boxes, em ordem');

  msg := tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 08:00', array['Alinhamento']) $q$, o),
                    'OF002', 'capacidade: o 5º carro no mesmo horário é recusado');
  perform tests.ok(msg like '%Próximos horários disponíveis: 04/03 09:00%',
    'capacidade: a recusa sugere o próximo horário livre (09:00)');

  perform tests.ok(
    (select count(*) from public.agendamentos where oficina_id = o and inicio < tests.t('2030-03-04 09:00')) = 4,
    'capacidade: nunca há mais agendamentos simultâneos do que boxes');
end $$;

-- Regra 3: sobreposição parcial
do $$
declare o uuid := tests.criar_oficina('Parcial'); a public.agendamentos;
begin
  update public.boxes set ativo = false where oficina_id = o and nome <> 'Box 1';
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);          -- 08:00-09:00
  perform tests.erro(format($q$ select regras.criar_agendamento(%L, %L, %L, array[%L]::uuid[], %L, null, null) $q$,
                            o, a.cliente_id, a.veiculo_id, tests.servico(o, 'Alinhamento'), tests.t('2030-03-04 08:30')),
                     'OF002', 'sobreposição: 08:30-09:30 com 08:00-09:00 no único box é recusado');
  perform tests.erro(format($q$ select regras.criar_agendamento(%L, %L, %L, array[%L]::uuid[], %L, null, null) $q$,
                            o, a.cliente_id, a.veiculo_id, tests.servico(o, 'Revisão'), tests.t('2030-03-04 07:30')),
                     'OF001', 'sobreposição: começar antes de abrir é recusado');
end $$;

-- Regra 3: um intervalo que engloba totalmente outro também conflita
do $$
declare o uuid := tests.criar_oficina('Engloba'); a public.agendamentos;
begin
  update public.boxes set ativo = false where oficina_id = o and nome <> 'Box 1';
  a := tests.agendar(o, '2030-03-04 09:00', array['Troca de óleo']);        -- 09:00-09:30
  perform tests.erro(format($q$ select regras.criar_agendamento(%L, %L, %L, array[%L]::uuid[], %L, null, null) $q$,
                            o, a.cliente_id, a.veiculo_id, tests.servico(o, 'Freios'), tests.t('2030-03-04 08:00')),
                     'OF002', 'sobreposição: 08:00-10:00 engloba 09:00-09:30 e é recusado');
end $$;

-- Borda exata: um termina 10:00, outro começa 10:00 = permitido no mesmo box
do $$
declare o uuid := tests.criar_oficina('Borda'); a1 public.agendamentos; a2 public.agendamentos; a0 public.agendamentos;
begin
  update public.boxes set ativo = false where oficina_id = o and nome <> 'Box 1';
  a1 := tests.agendar(o, '2030-03-04 09:00', array['Alinhamento']);         -- 09:00-10:00
  a2 := tests.agendar(o, '2030-03-04 10:00', array['Alinhamento']);         -- 10:00-11:00
  a0 := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);         -- 08:00-09:00
  perform tests.ok(a1.box_id = a2.box_id and a0.box_id = a1.box_id,
    'borda exata: 08-09, 09-10 e 10-11 cabem no mesmo box');
  perform tests.ok(a1.fim = tests.t('2030-03-04 10:00'), 'fim = início + soma das durações');
end $$;

-- Regra 2: box atribuído é livre durante TODO o intervalo (não só no início)
do $$
declare o uuid := tests.criar_oficina('Intervalo'); a public.agendamentos;
begin
  update public.boxes set ativo = false where oficina_id = o and nome not in ('Box 1', 'Box 2');
  -- Box 1 fica ocupado 08:30-09:00. Às 08:00 o Box 1 está livre no início,
  -- mas não no intervalo inteiro (08:00-09:00), então tem que ir para o Box 2.
  a := tests.agendar(o, '2030-03-04 08:30', array['Troca de óleo']);
  perform tests.ok(tests.box_nome(a.box_id) = 'Box 1', 'alocação: 08:30-09:00 vai para o Box 1');
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform tests.ok(tests.box_nome(a.box_id) = 'Box 2',
    'alocação: 08:00-09:00 pula o Box 1 (ocupado no meio do intervalo) e vai para o Box 2');
  perform tests.ok(
    not exists (select 1 from public.agendamentos x, public.agendamentos y
                 where x.oficina_id = o and y.oficina_id = o and x.id < y.id and x.box_id = y.box_id
                   and x.inicio < y.fim and x.fim > y.inicio),
    'alocação: nenhum par de agendamentos se sobrepõe no mesmo box');
end $$;

-- Mais serviços = soma das durações
do $$
declare o uuid := tests.criar_oficina('Soma'); a public.agendamentos;
begin
  a := tests.agendar(o, '2030-03-04 08:00', array['Troca de óleo', 'Alinhamento']);
  perform tests.ok(a.fim = tests.t('2030-03-04 09:30'), 'vários serviços: 30 + 60 min = fim 09:30');
  perform tests.ok((select count(*) from public.agendamento_servicos where agendamento_id = a.id) = 2,
    'vários serviços: os dois ficam registrados com preço e duração congelados');
end $$;

-- Regra 4: a constraint do banco barra sobreposição mesmo inserindo direto na tabela
do $$
declare o uuid := tests.criar_oficina('Constraint'); a public.agendamentos;
begin
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform tests.erro(format($q$ insert into public.agendamentos (oficina_id, cliente_id, veiculo_id, box_id, inicio, fim)
                                values (%L, %L, %L, %L, %L, %L) $q$,
                            o, a.cliente_id, a.veiculo_id, a.box_id,
                            tests.t('2030-03-04 08:30'), tests.t('2030-03-04 09:30')),
                     '23P01', 'constraint: insert direto sobreposto no mesmo box é barrado pelo Postgres');
end $$;

rollback;
