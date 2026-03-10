#!/usr/bin/env bash
# =============================================================================
# renew-ssl-if-needed.sh
# Проверяет сертификаты Let's Encrypt → renew только если ≤ 25 дней → reload nginx
# =============================================================================

set -euo pipefail

# Настройки
WARNING_DAYS=25
CERTBOT="/usr/bin/certbot"
RELOAD_CMD="systemctl reload nginx"

# Лог (опционально)
LOG="/var/log/ssl-renew.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запуск проверки" >> "$LOG" 2>/dev/null || true

# Получаем список всех сертификатов и их оставшихся дней
# Формат: имя_сертификата   дней_осталось
mapfile -t cert_lines < <(
    sudo "$CERTBOT" certificates 2>/dev/null |
    grep -E 'Certificate Name:|VALID:' |
    sed 's/^[[:space:]]*//' |
    awk '
        /Certificate Name:/ {name=$3; next}
        /VALID:/ { gsub(/.*VALID: *|\).*$/,""); print name " " $0 }
    '
)

need_renew=0
updated=0

for line in "${cert_lines[@]}"; do
    if [[ -z "$line" ]]; then continue; fi

    cert_name=$(echo "$line" | awk '{print $1}')
    days=$(echo "$line" | awk '{print $2}')

    # Проверяем, что days — это число
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "    Пропуск некорректной строки: $line" >> "$LOG" 2>/dev/null
        continue
    fi

    if (( days <= WARNING_DAYS )); then
        echo "    Сертификат $cert_name → осталось $days дней → нужен renew" >> "$LOG" 2>/dev/null
        need_renew=1
    else
        echo "    Сертификат $cert_name → осталось $days дней (ок)" >> "$LOG" 2>/dev/null
    fi
done

if (( need_renew == 0 )); then
    echo "    Все сертификаты в норме (> $WARNING_DAYS дней)" >> "$LOG" 2>/dev/null
    exit 0
fi

echo "    Запускаем renew..." >> "$LOG" 2>/dev/null

# Запускаем renew и смотрим, обновился ли хоть один сертификат
# --quiet убирает лишний вывод, но оставляем --deploy-hook если он настроен
renew_output=$(sudo "$CERTBOT" renew --quiet 2>&1)

# Проверяем, было ли реальное обновление (по ключевым словам в выводе)
if echo "$renew_output" | grep -q -i -E "renewing|renewed|successfully|new certificate"; then
    updated=1
    echo "    Обновление выполнено успешно" >> "$LOG" 2>/dev/null
else
    echo "    Renew запустился, но ничего не обновил" >> "$LOG" 2>/dev/null
fi

# Если обновилось — перезагружаем nginx
if (( updated == 1 )); then
    if $RELOAD_CMD; then
        echo "    nginx успешно перезагружен" >> "$LOG" 2>/dev/null
    else
        echo "    ОШИБКА: не удалось перезагрузить nginx" >> "$LOG" 2>/dev/null
        exit 2
    fi
else
    echo "    Перезагрузка nginx не требуется" >> "$LOG" 2>/dev/null
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Завершение" >> "$LOG" 2>/dev/null
exit 0
