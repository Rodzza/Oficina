-- Regras 6, 7 e 8, transições de status e histórico.
begin;

-- Regra 6: em atendimento / aguardando peça segura o box depois do fim previsto
do $$
declare o uuid := tests.criar_oficina('Peca'); a public.agendamentos; b public.agendamentos;
begin
  update public.boxes set ativo = false where oficina_id = o and nome <> 'Box 1';
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);          -- 08:00-09:00
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 10:00', array['Troca de óleo']) $q$, o),
    'OF002', 'regra 6: carro em atendimento segura o box depois do fim previsto');
  perform regras.mudar_status(o, a.id, 'aguardando_peca', 'Aguardando pastilha');
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-05 10:00', array['Troca de óleo']) $q$, o),
    'OF002', 'regra 6: aguardando peça segura o box até no dia seguinte');
  perform regras.mudar_status(o, a.id, 'concluido', null);
  b := tests.agendar(o, '2030-03-04 10:00', array['Troca de óleo']);
  perform tests.ok(b.box_id = a.box_id, 'regra 6: ao concluir, o box volta a ficar livre depois do fim');
end $$;

-- Regra 6: carro que passou do horário empurra o próximo agendamento para outro box
do $$
declare o uuid := tests.criar_oficina('Empurra'); a public.agendamentos; b public.agendamentos;
begin
  update public.boxes set ativo = false where oficina_id = o and nome not in ('Box 1', 'Box 2');
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);          -- Box 1
  b := tests.agendar(o, '2030-03-04 10:00', array['Alinhamento']);          -- Box 1 também
  perform tests.ok(a.box_id = b.box_id, 'preparo: os dois começam no Box 1');
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  select * into b from public.agendamentos where id = b.id;
  perform tests.ok(tests.box_nome(b.box_id) = 'Box 2',
    'regra 6: o agendamento das 10:00 foi realocado para o Box 2 automaticamente');
end $$;

-- Regra 6 + 8: sem outro box livre, o agendamento fica em conflito (não é apagado)
do $$
declare o uuid := tests.criar_oficina('SemSaida'); a public.agendamentos; b public.agendamentos; c record;
begin
  update public.boxes set ativo = false where oficina_id = o and nome <> 'Box 1';
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  b := tests.agendar(o, '2030-03-04 10:00', array['Alinhamento']);
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  perform tests.ok(exists (select 1 from public.agendamentos where id = b.id and status = 'agendado'),
    'regra 8: o agendamento afetado continua existindo');
  select * into c from public.agendamentos_em_conflito where agendamento_id = b.id;
  perform tests.ok(c.motivo like '%passou do horário%',
    'regra 8: aparece em agendamentos_em_conflito com o motivo');
end $$;

-- Regra 7: cancelamento libera a vaga na hora
do $$
declare o uuid := tests.criar_oficina('Cancela'); a public.agendamentos; ultimo public.agendamentos;
begin
  for i in 1..4 loop ultimo := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']); end loop;
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 08:00', array['Alinhamento']) $q$, o),
    'OF002', 'regra 7: lotado antes de cancelar');
  perform regras.mudar_status(o, ultimo.id, 'cancelado', 'Cliente desistiu');
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform tests.ok(a.box_id = ultimo.box_id, 'regra 7: depois de cancelar, a vaga é reaproveitada');

  perform regras.mudar_status(o, a.id, 'nao_compareceu', null);
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform tests.ok(a.id is not null, 'não compareceu também libera a vaga');
end $$;

-- Regra 8: desativar box realoca o que der e avisa o resto
do $$
declare o uuid := tests.criar_oficina('Desativa'); a public.agendamentos; b public.agendamentos; n int;
begin
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);          -- Box 1
  update public.boxes set ativo = false where oficina_id = o and nome = 'Box 1';
  select * into a from public.agendamentos where id = a.id;
  perform tests.ok(tests.box_nome(a.box_id) = 'Box 2', 'regra 8: ao desativar o box, o agendamento muda de box');

  -- Lota 08:00 nos boxes 2, 3 e 4 e depois reduz para 2 boxes ativos
  perform tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  update public.boxes set ativo = false where oficina_id = o and nome = 'Box 4';
  select count(*) into n from public.agendamentos where oficina_id = o and status = 'agendado';
  perform tests.ok(n = 3, 'regra 8: reduzir a capacidade não apaga agendamentos');
  select count(*) into n from public.agendamentos_em_conflito where oficina_id = o;
  perform tests.ok(n = 1, 'regra 8: o que não coube aparece como conflito');
  perform tests.ok((select motivo from public.agendamentos_em_conflito where oficina_id = o) like '%desativado%',
    'regra 8: motivo do conflito é o box desativado');
end $$;

-- Regra 8: mudar o horário de funcionamento também gera aviso
do $$
declare o uuid := tests.criar_oficina('Horario'); a public.agendamentos;
begin
  a := tests.agendar(o, '2030-03-04 17:00', array['Alinhamento']);
  update public.horarios_funcionamento set fecha = '17:00' where oficina_id = o and dia_semana = 1;
  perform tests.ok((select motivo from public.agendamentos_em_conflito where agendamento_id = a.id)
                   like 'Fora do horário%', 'regra 8: horário reduzido vira conflito, sem apagar');
end $$;

-- Transições e histórico
do $$
declare o uuid := tests.criar_oficina('Status'); a public.agendamentos; n int;
begin
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform tests.ok((select status_novo from public.historico_status where agendamento_id = a.id) = 'agendado',
    'histórico: criação registrada');
  perform regras.mudar_status(o, a.id, 'confirmado', 'Confirmou por WhatsApp');
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  perform regras.mudar_status(o, a.id, 'concluido', null);
  perform regras.mudar_status(o, a.id, 'entregue', null);
  select count(*) into n from public.historico_status where agendamento_id = a.id;
  perform tests.ok(n = 5, 'histórico: cada mudança fica registrada');
  perform tests.ok(exists (select 1 from public.historico_status
                            where agendamento_id = a.id and status_anterior = 'agendado'
                              and status_novo = 'confirmado' and observacao = 'Confirmou por WhatsApp'),
    'histórico: guarda de onde veio, para onde foi e a observação');
  perform tests.erro(format($q$ select regras.mudar_status(%L, %L, 'agendado', null) $q$, o, a.id),
    'OF004', 'transição: entregue não volta para agendado');

  a := tests.agendar(o, '2030-03-04 10:00', array['Alinhamento']);
  perform tests.erro(format($q$ select regras.mudar_status(%L, %L, 'entregue', null) $q$, o, a.id),
    'OF004', 'transição: agendado não pula direto para entregue');
  perform regras.mudar_status(o, a.id, 'cancelado', null);
  perform tests.erro(format($q$ select regras.mudar_status(%L, %L, 'confirmado', null) $q$, o, a.id),
    'OF004', 'transição: cancelado é final');
end $$;

rollback;
