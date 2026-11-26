#!/usr/bin/env bash
# Roda as migrações num banco limpo e executa todos os testes.
# Uso: DATABASE_URL=postgres://postgres@localhost:5432/postgres ./db/test.sh
# (o banco precisa ser um Postgres local descartável; o script cria e apaga "oficina_test")
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_URL="${DATABASE_URL:-postgres://postgres@localhost:5432/postgres}"
TEST_DB="oficina_test"
TEST_URL="${BASE_URL%/*}/${TEST_DB}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" "$BASE_URL" -c "drop database if exists ${TEST_DB} with (force)" -c "create database ${TEST_DB}"

"${PSQL[@]}" "$TEST_URL" -f db/supabase_stub.sql
for f in supabase/migrations/*.sql; do
  "${PSQL[@]}" "$TEST_URL" -f "$f"
done
"${PSQL[@]}" "$TEST_URL" -f db/tests/_helpers.sql

falhas=0
for f in db/tests/[0-9]*.sql; do
  echo "== $f"
  if ! "${PSQL[@]}" "$TEST_URL" -f "$f" 2>&1 | sed -e 's/^psql:[^ ]* NOTICE:  /  /' -e 's/^NOTICE:  /  /'; then
    falhas=$((falhas + 1))
  fi
done

echo "== seed de exemplo"
if "${PSQL[@]}" "$TEST_URL" -f supabase/seed.sql; then
  n=$("${PSQL[@]}" "$TEST_URL" -At -c "select count(*) from public.agendamentos where oficina_id = '11111111-1111-1111-1111-111111111111'")
  echo "  ok - seed carregado ($n agendamentos de exemplo)"
else
  echo "  FALHOU: seed"; falhas=$((falhas + 1))
fi

echo "== concorrência: duas reservas ao mesmo tempo para a última vaga"
"${PSQL[@]}" "$TEST_URL" <<'SQL'
delete from public.oficinas where nome = 'Concorrencia';
select tests.criar_oficina('Concorrencia');
update public.boxes set ativo = false
 where oficina_id = (select id from public.oficinas where nome = 'Concorrencia') and nome <> 'Box 1';
SQL
reserva() {
  "${PSQL[@]}" "$TEST_URL" -At 2>&1 <<SQL || true
begin;
select 'reservou ' || tests.box_nome(box_id)
  from tests.agendar((select id from public.oficinas where nome = 'Concorrencia'), '2030-03-04 08:00', array['Alinhamento']);
select pg_sleep(1);
commit;
SQL
}
reserva > /tmp/oficina_r1.txt & p1=$!
reserva > /tmp/oficina_r2.txt & p2=$!
wait $p1 $p2
cat /tmp/oficina_r1.txt /tmp/oficina_r2.txt | sed 's/^/  /'
total=$("${PSQL[@]}" "$TEST_URL" -At -c "select count(*) from public.agendamentos a join public.oficinas o on o.id = a.oficina_id where o.nome = 'Concorrencia'")
if [ "$total" = "1" ] && grep -q "OF002\|Não há box livre" /tmp/oficina_r1.txt /tmp/oficina_r2.txt; then
  echo "  ok - concorrência: só uma das duas reservas entrou, a outra foi recusada"
else
  echo "  FALHOU: concorrência (agendamentos gravados: $total)"
  falhas=$((falhas + 1))
fi

if [ "$falhas" -gt 0 ]; then
  echo "RESULTADO: $falhas arquivo(s) com falha"
  exit 1
fi
echo "RESULTADO: todos os testes passaram"
