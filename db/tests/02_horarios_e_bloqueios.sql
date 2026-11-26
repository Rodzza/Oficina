-- Regra 5 (expediente, almoço, bloqueios), box inativo e disponibilidade.
-- Segunda-feira 04/03/2030; domingo 03/03/2030; sábado 09/03/2030.
begin;

-- Almoço: serviço que atravessa o almoço pausa e termina depois
do $$
declare o uuid := tests.criar_oficina('Almoco'); a public.agendamentos;
begin
  a := tests.agendar(o, '2030-03-04 11:30', array['Alinhamento']);          -- 30 min antes + 30 min depois
  perform tests.ok(a.fim = tests.t('2030-03-04 13:30'),
    'almoço: 11:30 + 60 min atravessa o almoço e termina 13:30');
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 12:15', array['Troca de óleo']) $q$, o),
    'OF001', 'almoço: não dá para começar durante o almoço');
  a := tests.agendar(o, '2030-03-04 11:30', array['Troca de óleo']);        -- 11:30-12:00 não atravessa
  perform tests.ok(a.fim = tests.t('2030-03-04 12:00'), 'almoço: terminar exatamente 12:00 não empurra o fim');
  a := tests.agendar(o, '2030-03-04 13:00', array['Troca de óleo']);
  perform tests.ok(a.fim = tests.t('2030-03-04 13:30'), 'almoço: começar exatamente 13:00 é permitido');
end $$;

-- Expediente
do $$
declare o uuid := tests.criar_oficina('Expediente'); msg text;
begin
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 07:30', array['Troca de óleo']) $q$, o),
    'OF001', 'expediente: antes de abrir é recusado');
  msg := tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 17:30', array['Alinhamento']) $q$, o),
    'OF001', 'expediente: terminar depois de fechar (17:30 + 60) é recusado');
  perform tests.ok(msg like 'Fora do horário de funcionamento (08:00 às 18:00).%',
    'expediente: mensagem clara com o horário da oficina');
  perform tests.ok(msg like '%Próximos horários disponíveis: 05/03 08:00%',
    'expediente: sugere o próximo dia útil');
  perform tests.agendar(o, '2030-03-04 17:00', array['Alinhamento']);
  perform tests.ok(true, 'expediente: terminar exatamente 18:00 é permitido');
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-03 09:00', array['Troca de óleo']) $q$, o),
    'OF001', 'expediente: domingo (sem horário cadastrado) é recusado');
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-09 11:30', array['Alinhamento']) $q$, o),
    'OF001', 'expediente: sábado fecha 12:00, então 11:30 + 60 min é recusado');
end $$;

-- Sábado: meio período, 11:00 + 60 min termina exatamente 12:00 e é permitido
do $$
declare o uuid := tests.criar_oficina('Sabado'); a public.agendamentos;
begin
  a := tests.agendar(o, '2030-03-09 11:00', array['Alinhamento']);
  perform tests.ok(a.fim = tests.t('2030-03-09 12:00'), 'sábado: 11:00-12:00 cabe no meio período');
end $$;

-- Passado
do $$
declare o uuid := tests.criar_oficina('Passado');
begin
  perform tests.erro(format($q$ select tests.agendar(%L, '2020-03-02 09:00', array['Troca de óleo']) $q$, o),
    'OF001', 'passado: não agenda em horário que já passou');
end $$;

-- Bloqueio da oficina inteira (feriado)
do $$
declare o uuid := tests.criar_oficina('Feriado'); msg text;
begin
  insert into public.bloqueios (oficina_id, inicio, fim, motivo)
  values (o, tests.t('2030-03-04 00:00'), tests.t('2030-03-05 00:00'), 'Carnaval');
  msg := tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 09:00', array['Troca de óleo']) $q$, o),
    'OF001', 'bloqueio: feriado da oficina recusa agendamento');
  perform tests.ok(msg like '%Carnaval%', 'bloqueio: mensagem cita o motivo');
  perform tests.ok(not exists (select 1 from regras.disponibilidade(o, '2030-03-04', 30)),
    'bloqueio: disponibilidade do feriado vem vazia');
end $$;

-- Bloqueio de um box só (manutenção) e box inativo
do $$
declare o uuid := tests.criar_oficina('Manutencao'); a public.agendamentos; usados text[] := '{}';
begin
  insert into public.bloqueios (oficina_id, box_id, inicio, fim, motivo)
  select o, id, tests.t('2030-03-04 08:00'), tests.t('2030-03-04 12:00'), 'Elevador quebrado'
    from public.boxes where oficina_id = o and nome = 'Box 1';
  update public.boxes set ativo = false where oficina_id = o and nome = 'Box 2';

  for i in 1..2 loop
    a := tests.agendar(o, '2030-03-04 09:00', array['Alinhamento']);
    usados := usados || tests.box_nome(a.box_id);
  end loop;
  perform tests.ok(usados = array['Box 3', 'Box 4'],
    'box bloqueado e box inativo nunca recebem agendamento');
  perform tests.erro(format($q$ select tests.agendar(%L, '2030-03-04 09:00', array['Alinhamento']) $q$, o),
    'OF002', 'capacidade efetiva = boxes ativos e sem bloqueio (2)');
  a := tests.agendar(o, '2030-03-04 13:00', array['Alinhamento']);
  perform tests.ok(tests.box_nome(a.box_id) = 'Box 1', 'bloqueio do box acaba às 12:00 e ele volta a ser usado');
end $$;

-- disponibilidade(data, duração)
do $$
declare o uuid := tests.criar_oficina('Disp'); r record; n int;
begin
  -- Ocupa 3 dos 4 boxes às 08:00-09:00
  for i in 1..3 loop perform tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']); end loop;

  select * into r from regras.disponibilidade(o, '2030-03-04', 60) where inicio = tests.t('2030-03-04 08:00');
  perform tests.ok(r.vagas_livres = 1, 'disponibilidade: 08:00 tem 1 vaga livre');
  select * into r from regras.disponibilidade(o, '2030-03-04', 60) where inicio = tests.t('2030-03-04 09:00');
  perform tests.ok(r.vagas_livres = 4, 'disponibilidade: 09:00 tem 4 vagas livres');
  select * into r from regras.disponibilidade(o, '2030-03-04', 60) where inicio = tests.t('2030-03-04 08:30');
  perform tests.ok(r.vagas_livres = 1, 'disponibilidade: 08:30-09:30 sobrepõe e também tem 1 vaga');

  perform tests.ok(not exists (select 1 from regras.disponibilidade(o, '2030-03-04', 60)
                                where inicio in (tests.t('2030-03-04 12:00'), tests.t('2030-03-04 12:30'))),
    'disponibilidade: não oferece horários começando no almoço');
  select * into r from regras.disponibilidade(o, '2030-03-04', 60) where inicio = tests.t('2030-03-04 11:30');
  perform tests.ok(r.fim = tests.t('2030-03-04 13:30'), 'disponibilidade: slot 11:30 já mostra o fim depois do almoço');
  perform tests.ok((select max(inicio) from regras.disponibilidade(o, '2030-03-04', 60)) = tests.t('2030-03-04 17:00'),
    'disponibilidade: último slot de 60 min é 17:00');
  select count(*) into n from regras.disponibilidade(o, '2030-03-04', 180);
  perform tests.ok(n > 0 and (select max(inicio) from regras.disponibilidade(o, '2030-03-04', 180)) = tests.t('2030-03-04 15:00'),
    'disponibilidade: revisão de 3h tem último slot 15:00');
  perform tests.ok(not exists (select 1 from regras.disponibilidade(o, '2030-03-03', 30)),
    'disponibilidade: domingo vem vazio');

  perform tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  select * into r from regras.disponibilidade(o, '2030-03-04', 60) where inicio = tests.t('2030-03-04 08:00');
  perform tests.ok(r.vagas_livres = 0, 'disponibilidade: slot lotado aparece com 0 vagas');
end $$;

rollback;
