#!/usr/bin/env bash
# Backup lógico em formato customizado. Credenciais via .pgpass; conexão via PG*.
# Exemplo: PGDATABASE=erp_academico ./operacao/backup.sh /caminho/backups
set -euo pipefail
: "${PGDATABASE:?Defina PGDATABASE com o banco de origem}"
backup_dir="${1:?Informe o diretório de backup}"
umask 077
mkdir -p "$backup_dir"
backup_file="$backup_dir/${PGDATABASE}_$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-password --file="$backup_file"
pg_restore --list "$backup_file" > "$backup_file.manifesto.txt"
printf 'Backup criado: %s\n' "$backup_file"
# Execute em janela própria para copiar também os papéis globais (acesso DBA):
# pg_dumpall --roles-only --no-role-passwords --file=roles.sql
# O arquivo de backup contém dados sensíveis: cifre-o e aplique retenção externa.
