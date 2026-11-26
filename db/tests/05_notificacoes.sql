-- Aviso de carro pronto no WhatsApp: fila de notificações.
begin;

do $$
declare o uuid := tests.criar_oficina('Oficina Aviso'); a public.agendamentos; n public.notificacoes; qtd int;
begin
  update public.oficinas set telefone = '1133334444' where id = o;
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  perform tests.ok(not exists (select 1 from public.notificacoes where agendamento_id = a.id),
    'aviso: nada é enviado antes de ficar pronto');

  perform regras.mudar_status(o, a.id, 'concluido', null);
  select * into n from public.notificacoes where agendamento_id = a.id;
  perform tests.ok(n.status = 'pendente', 'aviso: ao concluir, cria uma notificação pendente');
  perform tests.ok(n.telefone = '5511999990000', 'aviso: telefone do dono do carro em formato internacional');
  perform tests.ok(n.mensagem = 'Olá, Cliente! Seu Gol placa ABC1D23 está pronto e já pode ser retirado na Oficina Aviso. Dúvidas: 1133334444',
    'aviso: mensagem com nome, carro, placa e oficina');
  perform tests.ok(n.parametros->>'carro' = 'Gol placa ABC1D23', 'aviso: parâmetros para o template da Meta');

  perform regras.mudar_status(o, a.id, 'entregue', null);
  select count(*) into qtd from public.notificacoes where agendamento_id = a.id;
  perform tests.ok(qtd = 1, 'aviso: só um aviso por agendamento');

  -- Oficina que desligou o aviso
  update public.oficinas set avisar_carro_pronto = false where id = o;
  a := tests.agendar(o, '2030-03-04 10:00', array['Alinhamento']);
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  perform regras.mudar_status(o, a.id, 'concluido', null);
  perform tests.ok(not exists (select 1 from public.notificacoes where agendamento_id = a.id),
    'aviso: oficina pode desligar o aviso');
end $$;

-- Fila da Edge Function: cada pendente é pega uma vez só
do $$
declare o uuid := tests.criar_oficina('Fila'); a public.agendamentos; qtd int;
begin
  a := tests.agendar(o, '2030-03-04 08:00', array['Alinhamento']);
  perform regras.mudar_status(o, a.id, 'em_atendimento', null);
  perform regras.mudar_status(o, a.id, 'concluido', null);
  select count(*) into qtd from public.pegar_notificacoes_pendentes(100) p where p.agendamento_id = a.id;
  perform tests.ok(qtd = 1, 'fila: a pendente é entregue para envio');
  select count(*) into qtd from public.pegar_notificacoes_pendentes(100) p where p.agendamento_id = a.id;
  perform tests.ok(qtd = 0, 'fila: não é entregue duas vezes');
end $$;

-- Telefones
do $$
begin
  perform tests.ok(regras.telefone_internacional('(11) 98765-0001') = '5511987650001', 'telefone: celular com DDD ganha 55');
  perform tests.ok(regras.telefone_internacional('5511987650001') = '5511987650001', 'telefone: já internacional fica igual');
end $$;

rollback;
