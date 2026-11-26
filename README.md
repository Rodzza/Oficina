# Oficina: agendamento de oficina mecânica

App de agendamento para oficina mecânica que **nunca deixa passar da capacidade de boxes**.
Pensado para uso no celular, com a base pronta para virar SaaS (várias oficinas).

**Stack:** Expo (React Native) + NativeWind (Tailwind) no app, Supabase (Postgres + Auth) no back.
Idioma pt-BR, fuso `America/Sao_Paulo`, moeda BRL.

## Situação

| Passo | O que é | Estado |
|---|---|---|
| 1 | Banco no Supabase: tabelas, regra de capacidade, permissões, testes e seed | **este PR** |
| 2 | App base Expo: login, perfis, cadastros | a fazer |
| 3 | Telas de agenda: agendar, grade do dia, pátio agora, status | a fazer |
| 4 | Entrega: testes com a oficina, publicação, dados reais | a fazer |

## Estrutura

```
supabase/
  migrations/
    ..._schema.sql             tabelas, constraint de exclusão, triggers
    ..._regras_capacidade.sql  disponibilidade, alocação, status, conflitos
    ..._api_e_rls.sql          funções RPC do app e segurança por oficina/perfil
  seed.sql                     oficina de exemplo com 4 boxes, 10 serviços, clientes e agendamentos
db/
  supabase_stub.sql            imita o mínimo do Supabase para testar num Postgres puro
  tests/                       testes das regras (SQL)
  test.sh                      roda migrações + testes num banco descartável
```

## Como a capacidade é garantida

A regra mora **dentro do Postgres**, não no app. Assim nenhum caminho (app, painel do Supabase,
duas atendentes ao mesmo tempo) consegue colocar mais carros do que boxes.

1. **Constraint de exclusão** em `agendamentos`: dois agendamentos ativos nunca se sobrepõem no
   mesmo box (`tstzrange(inicio, fim, '[)')`). Um termina 10:00 e outro começa 10:00 é permitido.
2. **`criar_agendamento`** trava a agenda da oficina (`pg_advisory_xact_lock`), calcula o fim pela
   soma das durações, valida expediente/almoço/bloqueios e escolhe o **primeiro box livre durante
   todo o intervalo**. Sem box livre, recusa com erro `OF002` e sugere os próximos horários.
3. **Em atendimento / aguardando peça** seguram o box até mudar de status, mesmo depois do fim
   previsto. Os próximos agendamentos daquele box são movidos para outro box livre.
4. **Reduzir capacidade** (desativar box, bloquear, mudar horário) nunca apaga nada: o que não couber
   aparece na view `agendamentos_em_conflito` com o motivo.
5. **RLS**: cada usuário só vê a própria oficina. Agendamentos só são criados/alterados pelas
   funções, nunca por `insert` direto.

### Decisões que tomei (dá para mudar)

- **Capacidade = nº de boxes ativos.** Não existe um campo separado de capacidade, para não haver
  dois números que podem discordar.
- **Serviço que atravessa o almoço pausa:** 11:30 + 60 min termina 13:30, e o box fica ocupado
  durante o almoço. Não é possível começar durante o almoço.
- **Status `concluido`** (carro pronto, esperando o dono) ocupa o box só até o fim previsto, como
  diz a regra 6. Se o carro costuma ficar no box até ser retirado, é só incluir `concluido` em
  `regras.segura_box`.
- **Transições de status permitidas:** agendado → confirmado / em atendimento / cancelado / não
  compareceu; confirmado → em atendimento / cancelado / não compareceu; em atendimento ⇄ aguardando
  peça; ambos → concluído; concluído → entregue. Cancelado, não compareceu e entregue são finais.
- **Perfis:** admin configura tudo; atendente agenda e cadastra clientes/veículos; mecânico só
  movimenta o trabalho no box (em atendimento, aguardando peça, concluído).

## API para o app (supabase-js)

```ts
// horários do dia com vagas livres (inclui os lotados, com vagas_livres = 0)
const { data } = await supabase.rpc('disponibilidade', { p_data: '2026-12-01', p_duracao_min: 90 })

// criar agendamento (o box é escolhido sozinho)
const { data, error } = await supabase.rpc('criar_agendamento', {
  p_cliente_id, p_veiculo_id, p_servicos: [idOleo, idAlinhamento], p_inicio: '2026-12-01T08:00:00-03:00',
})
// error.code === 'OF002' -> sem vaga; error.hint traz "Próximos horários disponíveis: ..."
// error.details traz os mesmos horários em JSON

await supabase.rpc('mudar_status', { p_agendamento_id, p_status: 'em_atendimento' })
await supabase.rpc('proximos_horarios', { p_a_partir: new Date().toISOString(), p_duracao_min: 60 })
await supabase.rpc('registrar_oficina', { p_nome_oficina: 'Auto Center X', p_seu_nome: 'Rodrigo' }) // 1º acesso

// leitura direta (já filtrada pela oficina do usuário)
supabase.from('patio_agora').select('*')
supabase.from('agendamentos_em_conflito').select('*')
```

Códigos de erro: `OF001` horário inválido, `OF002` sem box livre, `OF003` dados inválidos,
`OF004` mudança de status não permitida, `42501` sem permissão.

## Rodando

### Testes (só precisa de um Postgres 15+ com `btree_gist`)

```bash
DATABASE_URL=postgres://postgres@localhost:5432/postgres ./db/test.sh
```

O script cria e apaga o banco `oficina_test`, aplica as migrações, roda os testes, carrega o seed e
faz um teste de concorrência com duas reservas simultâneas para a última vaga. Os testes também
rodam no GitHub Actions a cada push.

### Supabase local

```bash
npm i -g supabase          # ou: brew install supabase/tap/supabase
supabase init              # cria supabase/config.toml (mantém migrations e seed)
supabase start
supabase db reset          # aplica migrações + seed.sql
```

Para entrar com a oficina de exemplo: crie um usuário em Authentication no Studio local e rode no SQL
editor `select seed_vincular_usuario('seu@email.com', 'admin');`.

### Supabase na nuvem

```bash
supabase link --project-ref <ref-do-projeto>
supabase db push           # aplica as migrações (não roda o seed)
```
