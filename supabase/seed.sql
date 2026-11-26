-- Dados de exemplo para desenvolvimento (rodado por `supabase db reset`).
-- 1 oficina, 4 boxes, 10 serviços comuns, 8 clientes com veículo e
-- agendamentos fictícios nos próximos dias úteis.
-- Para entrar no app com esta oficina, crie um usuário em Authentication e
-- rode: select seed_vincular_usuario('email@exemplo.com', 'admin');

do $$
declare
  o uuid := '11111111-1111-1111-1111-111111111111';
  dia date;
  clientes uuid[];
  veiculos uuid[];
  servs jsonb;
  ag record;
  i int := 0;
  horarios text[] := array['08:00', '08:00', '08:30', '09:00', '10:00', '13:00', '14:00', '15:30'];
  pacotes text[] := array[
    'Troca de óleo e filtro', 'Alinhamento|Balanceamento', 'Revisão completa',
    'Freios (pastilhas e discos)', 'Diagnóstico eletrônico', 'Troca de óleo e filtro|Alinhamento',
    'Suspensão', 'Ar-condicionado (higienização)'
  ];
begin
  insert into public.oficinas (id, nome, telefone, endereco)
  values (o, 'Oficina Exemplo', '11999990000', 'Rua das Oficinas, 100 - São Paulo/SP')
  on conflict (id) do nothing;

  insert into public.horarios_funcionamento (oficina_id, dia_semana, abre, fecha, almoco_inicio, almoco_fim)
  select o, d, time '08:00', time '18:00', time '12:00', time '13:00' from generate_series(1, 5) d
  on conflict do nothing;
  insert into public.horarios_funcionamento (oficina_id, dia_semana, abre, fecha)
  values (o, 6, '08:00', '12:00') on conflict do nothing;

  insert into public.boxes (oficina_id, nome, ordem)
  select o, 'Box ' || n, n from generate_series(1, 4) n
  on conflict do nothing;

  insert into public.servicos (oficina_id, nome, duracao_estimada_min, preco_base) values
    (o, 'Troca de óleo e filtro',          30,  180.00),
    (o, 'Alinhamento',                     60,  120.00),
    (o, 'Balanceamento',                   30,   80.00),
    (o, 'Revisão completa',               180,  650.00),
    (o, 'Freios (pastilhas e discos)',    120,  450.00),
    (o, 'Diagnóstico eletrônico',          60,  150.00),
    (o, 'Suspensão',                      150,  700.00),
    (o, 'Ar-condicionado (higienização)',  60,  200.00),
    (o, 'Troca de bateria',                30,   60.00),
    (o, 'Troca de correia dentada',       180,  550.00)
  on conflict do nothing;

  with novos as (
    insert into public.clientes (oficina_id, nome, telefone, email) values
      (o, 'João Silva',      '11987650001', 'joao@exemplo.com'),
      (o, 'Maria Oliveira',  '11987650002', null),
      (o, 'Carlos Souza',    '11987650003', null),
      (o, 'Ana Pereira',     '11987650004', 'ana@exemplo.com'),
      (o, 'Pedro Santos',    '11987650005', null),
      (o, 'Juliana Costa',   '11987650006', null),
      (o, 'Ricardo Lima',    '11987650007', null),
      (o, 'Fernanda Rocha',  '11987650008', null)
    returning id, nome
  )
  select array_agg(id order by nome) into clientes from novos;

  with v as (
    insert into public.veiculos (oficina_id, cliente_id, placa, marca, modelo, ano, cor, km)
    select o, clientes[n], p.placa, p.marca, p.modelo, p.ano, p.cor, p.km
      from (values
        (1, 'BRA2E19', 'Volkswagen', 'Gol',     2018, 'Prata',    85000),
        (2, 'QWE4R56', 'Chevrolet',  'Onix',    2021, 'Branco',   32000),
        (3, 'RTY7U89', 'Fiat',       'Argo',    2020, 'Vermelho', 47000),
        (4, 'UIO1P23', 'Hyundai',    'HB20',    2019, 'Preto',    61000),
        (5, 'ASD4F56', 'Toyota',     'Corolla', 2017, 'Cinza',   112000),
        (6, 'GHJ7K89', 'Honda',      'Civic',   2016, 'Azul',    128000),
        (7, 'ZXC1V23', 'Renault',    'Kwid',    2022, 'Branco',   15000),
        (8, 'BNM4Q56', 'Jeep',       'Renegade',2020, 'Verde',    54000)
      ) as p(n, placa, marca, modelo, ano, cor, km)
    returning id, cliente_id
  )
  select array_agg(v.id order by c.nome) into veiculos
    from v join public.clientes c on c.id = v.cliente_id;

  -- Agendamentos nos próximos 3 dias úteis, pelo caminho oficial (respeita capacidade).
  for dia in select d::date from generate_series(current_date + 1, current_date + 7, interval '1 day') d
              where extract(dow from d) between 1 and 5 limit 3 loop
    for n in 1..array_length(horarios, 1) loop
      i := i + 1;
      begin
        perform regras.criar_agendamento(
          o, clientes[((i + extract(day from dia)::int) % 8) + 1], veiculos[((i + extract(day from dia)::int) % 8) + 1],
          (select array_agg(s.id) from public.servicos s
            where s.oficina_id = o and s.nome = any (string_to_array(pacotes[((i * 3 + extract(day from dia)::int) % 8) + 1], '|'))),
          (dia + horarios[n]::time) at time zone 'America/Sao_Paulo',
          null, null);
      exception when sqlstate 'OF001' or sqlstate 'OF002' then
        null; -- horário cheio: ignora, é só dado de exemplo
      end;
    end loop;
  end loop;
end $$;

-- Vincula um usuário já criado no Supabase Auth à oficina de exemplo.
create or replace function public.seed_vincular_usuario(p_email text, p_perfil public.perfil_usuario default 'admin')
returns void language sql security definer set search_path = public as $$
  insert into public.perfis (id, oficina_id, nome, perfil)
  select u.id, '11111111-1111-1111-1111-111111111111', split_part(u.email, '@', 1), p_perfil
    from auth.users u where u.email = p_email
  on conflict (id) do update set perfil = excluded.perfil
$$;
revoke execute on function public.seed_vincular_usuario(text, public.perfil_usuario) from public, anon, authenticated;
