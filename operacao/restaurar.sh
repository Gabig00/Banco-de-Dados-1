#!/usr/bin/env bash
# Exige banco NOVO já criado; não contém --clean e não apaga o banco existente.
# Exemplo: ./operacao/restaurar.sh copia.dump erp_restauracao_teste
# Restauração portátil sem donos/ACL; para testar RBAC execute operacao/reaplicar_permissoes.sql após restaurar,
# com um administrador. Para recuperação fiel de produção, restaure roles e ACLs.
set -euo pipefail
backup_file="${1:?Informe o arquivo .dump}"
target_db="${2:?Informe um banco NOVO de destino}"
objects=$(psql -X -At --dbname="$target_db" -v ON_ERROR_STOP=1 -c \
 "SELECT count(*) FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname NOT IN ('public','information_schema')")
if [[ "$objects" != 0 ]]; then
  printf 'Destino contém schemas de usuário; restauração recusada.\n' >&2
  exit 1
fi
pg_restore --exit-on-error --single-transaction --no-owner --no-acl --dbname="$target_db" "$backup_file"
printf 'Restaurado em %s. Valide os dados e reaplique o RBAC antes do uso.\n' "$target_db"
