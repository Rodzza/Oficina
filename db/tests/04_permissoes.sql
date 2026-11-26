-- Permissões: RLS por oficina, perfis e funções RPC chamadas como usuário logado.
begin;

create or replace function tests.como(p_usuario uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  if p_usuario is null then
    execute 'set local role anon';
  else
    execute 'set local role authenticated';
  end if;
end $$;
create or replace function tests.como_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
grant usage on schema tests to anon, authenticated;
grant execute on all functions in schema tests to anon, authenticated;

do $$
declare
  oa uuid := tests.criar_oficina('Oficina A');
  ob uuid := tests.criar_oficina('Oficina B');
  admin_a  uuid := '00000000-0000-0000-0000-00000000000a';
  atend_a  uuid := '00000000-0000-0000-0000-00000000000b';
  mec_a    uuid := '00000000-0000-0000-0000-00000000000c';
  admin_b  uuid := '00000000-0000-0000-0000-00000000000d';
  novo     uuid := '00000000-0000-0000-0000-00000000000e';
  cli uuid; vei uuid; ag public.agendamentos; n int; v_of public.oficinas;
begin
  insert into auth.users (id) values (admin_a), (atend_a), (mec_a), (admin_b), (novo);
  insert into public.perfis (id, oficina_id, nome, perfil) values
    (admin_a, oa, 'Ana', 'admin'), (atend_a, oa, 'Beto', 'atendente'),
    (mec_a, oa, 'Caio', 'mecanico'), (admin_b, ob, 'Dani', 'admin');

  -- Atendente da oficina A
  perform tests.como(atend_a);
  select count(*) into n from public.clientes;
  perform tests.ok(n = 1, 'RLS: atendente vê só os clientes da própria oficina');
  perform tests.ok(not exists (select 1 from public.boxes where oficina_id = ob),
    'RLS: não enxerga boxes de outra oficina');

  insert into public.clientes (nome, telefone) values ('Novo Cliente', '11 98888-7777') returning id into cli;
  insert into public.veiculos (cliente_id, placa, modelo) values (cli, 'XYZ9A87', 'Onix') returning id into vei;
  perform tests.ok((select oficina_id from public.clientes where id = cli) = oa,
    'cadastro: oficina_id é preenchido sozinho');
  perform tests.ok((select telefone from public.clientes where id = cli) = '11988887777',
    'cadastro: telefone normalizado só com dígitos');

  perform tests.ok((select count(*) from public.disponibilidade('2030-03-04', 60)) > 0,
    'RPC: atendente consulta disponibilidade');
  ag := public.criar_agendamento(cli, vei, array[tests.servico(oa, 'Alinhamento')], tests.t('2030-03-04 08:00'));
  perform tests.ok(ag.criado_por = atend_a and ag.oficina_id = oa,
    'RPC: atendente cria agendamento; criado_por e oficina vêm do login');
  perform tests.ok((select alterado_por from public.historico_status where agendamento_id = ag.id) = atend_a,
    'histórico: registra quem criou');

  perform tests.erro(format($q$ insert into public.agendamentos (oficina_id, cliente_id, veiculo_id, box_id, inicio, fim)
                                select %L, %L, %L, id, %L, %L from public.boxes where oficina_id = %L limit 1 $q$,
                            oa, cli, vei, tests.t('2030-03-04 15:00'), tests.t('2030-03-04 16:00'), oa),
                     '42501', 'RLS: insert direto em agendamentos é proibido (só pela função)');

  update public.boxes set ativo = false where oficina_id = oa;
  perform tests.como_postgres();
  perform tests.ok((select count(*) from public.boxes where oficina_id = oa and ativo) = 4,
    'RLS: atendente não altera configuração de boxes');

  -- Mecânico
  perform tests.como(mec_a);
  perform tests.erro(format($q$ select public.criar_agendamento(%L, %L, array[%L]::uuid[], %L) $q$,
                            cli, vei, tests.servico(oa, 'Alinhamento'), tests.t('2030-03-04 10:00')),
                     '42501', 'perfil: mecânico não cria agendamento');
  perform public.mudar_status(ag.id, 'em_atendimento');
  perform tests.ok(true, 'perfil: mecânico coloca em atendimento');
  perform tests.erro(format($q$ select public.mudar_status(%L, 'cancelado') $q$, ag.id),
                     '42501', 'perfil: mecânico não cancela');

  -- Admin de outra oficina
  perform tests.como(admin_b);
  perform tests.erro(format($q$ select public.mudar_status(%L, 'concluido') $q$, ag.id),
                     'OF003', 'RLS: oficina B não mexe em agendamento da oficina A');
  perform tests.erro(format($q$ select public.criar_agendamento(%L, %L, array[%L]::uuid[], %L) $q$,
                            cli, vei, tests.servico(oa, 'Alinhamento'), tests.t('2030-03-04 10:00')),
                     'OF003', 'RLS: oficina B não agenda com cliente da oficina A');

  -- Admin da própria oficina altera configuração
  perform tests.como(admin_a);
  update public.boxes set nome = 'Box Rápido' where oficina_id = oa and nome = 'Box 4';
  perform tests.ok(exists (select 1 from public.boxes where nome = 'Box Rápido'), 'perfil: admin altera boxes');

  -- Anônimo
  perform tests.como(null);
  perform tests.erro($q$ select * from public.disponibilidade('2030-03-04', 60) $q$,
                     '42501', 'anônimo: não acessa a agenda');

  -- Primeiro acesso: usuário sem oficina cria a sua
  perform tests.como(novo);
  v_of := public.registrar_oficina('Auto Center Novo', 'Eva');
  perform tests.ok((select count(*) from public.boxes) = 4, 'cadastro: nova oficina já nasce com 4 boxes');
  perform tests.ok(regras.meu_perfil() = 'admin', 'cadastro: quem cria a oficina vira admin');
  perform tests.erro($q$ select public.registrar_oficina('Outra', 'Eva') $q$,
                     'OF003', 'cadastro: não cria uma segunda oficina para o mesmo usuário');

  perform tests.como_postgres();
end $$;

rollback;
