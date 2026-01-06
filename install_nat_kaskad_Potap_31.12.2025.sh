#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- КОНСТАНТЫ ---
RULES_FILE="/etc/iptables/rules.sh"
BACKUP_FILE="/etc/iptables/rules.sh.backup"

# --- БАННЕР ---
show_banner() {
    clear
    echo -e "${MAGENTA}******************************************************${NC}"
    echo -e "${MAGENTA}        Каскадная переадресация портов${NC}"
    echo -e "${MAGENTA}           Потапу привеД передай :)${NC}"
    echo -e "${MAGENTA}******************************************************${NC}"
    echo ""
}

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"
        exit 1
    fi
}

# --- РАБОТА С ФАЙЛОМ ПРАВИЛ ---

# Инициализация файла правил
init_iptables_file() {
    if [ ! -f "$RULES_FILE" ]; then
        echo -e "${YELLOW}[*] Создание файла правил iptables...${NC}"
        mkdir -p /etc/iptables
        
        # Базовые правила в формате bash команд
        cat > "$RULES_FILE" << 'EOF'
#!/bin/bash
# Файл правил iptables
# Этот файл содержит команды для восстановления правил iptables

# Очистка старых правил
iptables -t nat -F
iptables -t mangle -F
iptables -F
iptables -X

# Базовые политики
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Правила для loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Принять уже установленные соединения
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# Разрешить пинг (ICMP)
iptables -A INPUT -p icmp -j ACCEPT
EOF
        chmod +x "$RULES_FILE"
        echo -e "${GREEN}[OK] Файл правил создан: $RULES_FILE${NC}"
    fi
}

# Выполнение файла правил
load_iptables_rules() {
    echo -e "${YELLOW}[*] Загрузка правил из файла...${NC}"
    if [ -f "$RULES_FILE" ] && [ -x "$RULES_FILE" ]; then
        bash "$RULES_FILE"
        echo -e "${GREEN}[OK] Правила загружены${NC}"
    else
        echo -e "${RED}[WARN] Файл правил не найден или не исполняемый${NC}"
        echo -e "${YELLOW}[*] Применяем базовые правила...${NC}"
        
        # Минимальные базовые правила
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
    fi
}

# Сохранение текущих правил в файл
save_iptables_rules() {
    echo -e "${YELLOW}[*] Сохранение правил в файл...${NC}"
    
    # Создаем новый файл с заголовком
    cat > "$RULES_FILE" << 'EOF'
#!/bin/bash
# Файл правил iptables
# Этот файл содержит команды для восстановления правил iptables
# Сгенерировано: $(date)

echo "Загрузка правил iptables..."

# Очистка старых правил
iptables -t nat -F
iptables -t mangle -F
iptables -F
iptables -X

# Базовые политики
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Правила для loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Принять уже установленные соединения
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# Разрешить пинг (ICMP)
iptables -A INPUT -p icmp -j ACCEPT
EOF
    
    # Собираем все текущие правила iptables и конвертируем их в команды bash
    echo -e "\n# --- NAT правила ---" >> "$RULES_FILE"
    
    # Получаем интерфейс по умолчанию
    local IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk -- '{printf $5}')
    if [[ -n "$IFACE" ]]; then
        echo "# MASQUERADE для интерфейса $IFACE" >> "$RULES_FILE"
        echo "iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE" >> "$RULES_FILE"
    fi
    
    # Добавляем все правила PREROUTING (DNAT)
    iptables -t nat -S PREROUTING 2>/dev/null | grep -v "^-N" | grep -v "^:" | while read rule; do
        # Заменяем -A на iptables -t nat -A
        if [[ "$rule" == -* ]]; then
            echo "iptables -t nat $rule" >> "$RULES_FILE"
        fi
    done
    
    # Добавляем INPUT правила
    echo -e "\n# --- INPUT правила ---" >> "$RULES_FILE"
    iptables -S INPUT 2>/dev/null | grep -v "^-N" | grep -v "^:" | grep -v "lo" | grep -v "RELATED,ESTABLISHED" | grep -v "icmp" | while read rule; do
        if [[ "$rule" == -* ]] && [[ ! "$rule" == *"DROP"* ]] && [[ ! "$rule" == *"REJECT"* ]]; then
            echo "iptables $rule" >> "$RULES_FILE"
        fi
    done
    
    # Добавляем FORWARD правила
    echo -e "\n# --- FORWARD правила ---" >> "$RULES_FILE"
    iptables -S FORWARD 2>/dev/null | grep -v "^-N" | grep -v "^:" | while read rule; do
        if [[ "$rule" == -* ]] && [[ ! "$rule" == *"DROP"* ]] && [[ ! "$rule" == *"REJECT"* ]]; then
            echo "iptables $rule" >> "$RULES_FILE"
        fi
    done
    
    echo -e "\necho \"Правила загружены успешно!\"" >> "$RULES_FILE"
    
    chmod +x "$RULES_FILE"
    
    # Создаем резервную копию
    cp "$RULES_FILE" "$BACKUP_FILE"
    
    echo -e "${GREEN}[OK] Правила сохранены в $RULES_FILE${NC}"
    echo -e "${GREEN}[OK] Резервная копия создана: $BACKUP_FILE${NC}"
}

# Проверка существования правила
rule_exists() {
    local proto="$1"
    local port="$2"
    local target_ip="$3"
    
    # Проверяем в текущих правилах iptables
    iptables -t nat -S PREROUTING 2>/dev/null | grep -q "dport $port.*to-destination $target_ip:$port"
    return $?
}

# Удаление правила
remove_rule() {
    local proto="$1"
    local port="$2"
    local target_ip="$3"
    
    echo -e "${YELLOW}[*] Удаление правила...${NC}"
    
    # Пытаемся удалить правило несколько раз (на случай если оно добавлено несколько раз)
    while iptables -t nat -D PREROUTING -p $proto --dport "$port" -j DNAT --to-destination "$target_ip:$port" 2>/dev/null; do
        echo -e "${YELLOW}[*] Удалено DNAT правило${NC}"
    done
    
    while iptables -D INPUT -p $proto --dport "$port" -j ACCEPT 2>/dev/null; do
        echo -e "${YELLOW}[*] Удалено INPUT правило${NC}"
    done
    
    while iptables -D FORWARD -p $proto -d "$target_ip" --dport "$port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
        echo -e "${YELLOW}[*] Удалено FORWARD правило (входящее)${NC}"
    done
    
    while iptables -D FORWARD -p $proto -s "$target_ip" --sport "$port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
        echo -e "${YELLOW}[*] Удалено FORWARD правило (исходящее)${NC}"
    done
    
    echo -e "${GREEN}[OK] Правило удалено из iptables${NC}"
}

# --- ПОДГОТОВКА СИСТЕМЫ ---
prepare_system() {
    # Включение IP Forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi

    # Активация Google BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null

    echo -e "${GREEN}[OK] Система подготовлена${NC}"
}

# --- ИНСТРУКЦИЯ ---
show_instructions() {
    clear
    show_banner
    echo -e "${MAGENTA}             📚 ИНСТРУКЦИЯ: КАК НАСТРОИТЬ КАСКАД              ${NC}"
    echo ""
    echo -e "${CYAN}ШАГ 1: Подготовка${NC}"
    echo -e "У вас должны быть данные от зарубежного VPN (WireGuard/VLESS):"
    echo -e " - ${YELLOW}IP адрес${NC} (зарубежный)"
    echo -e " - ${YELLOW}Порт${NC} (на котором работает VPN)"
    echo ""
    echo -e "${CYAN}ШАГ 2: Настройка этого сервера${NC}"
    echo -e "1. В меню выберите пункт ${GREEN}1${NC} (для UDP/VPN) или ${GREEN}2${NC} (для TCP/Proxy)."
    echo -e "2. Введите ${YELLOW}IP${NC} и ${YELLOW}Порт${NC} зарубежного сервера."
    echo -e "3. Скрипт создаст 'мост' через этот VPS."
    echo ""
    echo -e "${CYAN}ШАГ 3: Настройка Клиента (Важно!)${NC}"
    echo -e "1. Откройте приложение (AmneziaWG / WireGuard / v2rayNG)."
    echo -e "2. В настройках соединения найдите поле ${YELLOW}Endpoint / Адрес сервера${NC}."
    echo -e "3. Замените зарубежный IP на ${GREEN}IP ЭТОГО СЕРВЕРА${NC}."
    echo -e "4. Порт оставьте прежним."
    echo ""
    echo -e "${GREEN}Готово! Теперь трафик идет: Клиент -> Этот Сервер -> Зарубеж.${NC}"
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# --- ЯДРО НАСТРОЙКИ ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    while true; do
        echo -e "Введите IP адрес назначения:"
        read -p "> " TARGET_IP
        if [[ -n "$TARGET_IP" ]]; then break; fi
    done

    while true; do
        echo -e "Введите Порт (входной и выходной):"
        read -p "> " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом!${NC}"
    done

    # Получаем интерфейс
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk -- '{printf $5}')
    if [[ -z "$IFACE" ]]; then
        IFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
    fi
    
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Не удалось определить интерфейс!${NC}"
        read -p "Введите интерфейс вручную (например eth0): " IFACE
        if [[ -z "$IFACE" ]]; then
            exit 1
        fi
    fi

    echo -e "${YELLOW}[*] Применение правил...${NC}"

    # Проверяем и удаляем старое правило если есть
    if rule_exists "$PROTO" "$PORT" "$TARGET_IP"; then
        echo -e "${YELLOW}[*] Правило уже существует, удаляем старое...${NC}"
        remove_rule "$PROTO" "$PORT" "$TARGET_IP"
    fi

    # Добавляем новые правила
    iptables -A INPUT -p $PROTO --dport "$PORT" -j ACCEPT
    iptables -t nat -A PREROUTING -p $PROTO --dport "$PORT" -j DNAT --to-destination "$TARGET_IP:$PORT"
    
    # Добавляем MASQUERADE если еще нет
    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    iptables -A FORWARD -p $PROTO -d "$TARGET_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -p $PROTO -s "$TARGET_IP" --sport "$PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Сохраняем все правила в файл
    save_iptables_rules
    
    echo -e "${GREEN}[SUCCESS] Туннель настроен!${NC}"
    echo -e "$PROTO: Порт $PORT -> $TARGET_IP:$PORT"
    echo -e "${YELLOW}[INFO] Правила сохранены в файл: $RULES_FILE${NC}"
    
    # Показываем текущий IP сервера
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${CYAN}[TIP] В вашей конфигурации VPN поменяйте IP адрес на: $SERVER_IP${NC}"
    
    read -p "Нажмите Enter для возврата в меню..."
}

# --- СПИСОК ПРАВИЛ ---
list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации ---${NC}"
    echo -e "${MAGENTA}ПОРТ\tПРОТОКОЛ\tЦЕЛЬ${NC}"
    
    iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT" | while read -r line ; do
        l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_port" ]]; then 
            echo -e "$l_port\t$l_proto\t\t$l_dest"
        fi
    done
    
    echo ""
    echo -e "${CYAN}--- Общее количество правил ---${NC}"
    echo -e "INPUT: $(iptables -S INPUT 2>/dev/null | wc -l)"
    echo -e "FORWARD: $(iptables -S FORWARD 2>/dev/null | wc -l)"
    echo -e "NAT PREROUTING: $(iptables -t nat -S PREROUTING 2>/dev/null | wc -l)"
    
    echo ""
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ОДНОГО ПРАВИЛА ---
delete_single_rule() {
    echo -e "\n${CYAN}--- Удаление правила ---${NC}"
    declare -a RULES_LIST
    local i=0
    
    # Собираем правила из iptables
    while read -r line; do
        l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_port" ]]; then
            ((i++))
            RULES_LIST[$i]="$l_port:$l_proto:$l_dest"
            echo -e "${YELLOW}[$i]${NC} Порт: $l_port ($l_proto) -> $l_dest"
        fi
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT")

    if [ $i -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Номер правила для удаления (0 отмена): " rule_num
    
    # Проверка ввода
    if [[ ! "$rule_num" =~ ^[0-9]+$ ]] || [ "$rule_num" -lt 0 ] || [ "$rule_num" -gt $i ]; then
        echo -e "${RED}Неверный номер правила${NC}"
        read -p "Нажмите Enter..."
        return
    fi
    
    if [[ "$rule_num" == "0" ]]; then 
        return
    fi

    IFS=':' read -r d_port d_proto d_dest <<< "${RULES_LIST[$rule_num]}"
    
    echo -e "${YELLOW}[*] Удаление правила: Порт $d_port ($d_proto) -> $d_dest${NC}"
    
    # Извлекаем IP из цели (убираем порт)
    TARGET_IP=$(echo "$d_dest" | cut -d: -f1)
    
    # Удаляем правило
    remove_rule "$d_proto" "$d_port" "$TARGET_IP"
    
    # Сохраняем изменения
    save_iptables_rules
    
    echo -e "${GREEN}[OK] Правило удалено.${NC}"
    read -p "Нажмите Enter..."
}

# --- ПОЛНАЯ ОЧИСТКА ---
flush_rules() {
    echo -e "\n${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo "Сброс ВСЕХ настроек iptables и файла правил."
    read -p "Вы уверены? (y/n): " confirm
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        # Очищаем текущие правила
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        
        # Восстанавливаем базовый файл правил
        init_iptables_file
        
        echo -e "${GREEN}[OK] Все правила сброшены.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- ПРОСМОТР ФАЙЛА ПРАВИЛ ---
view_rules_file() {
    echo -e "\n${CYAN}--- Содержимое файла правил ($RULES_FILE) ---${NC}"
    if [ -f "$RULES_FILE" ]; then
        cat "$RULES_FILE"
    else
        echo -e "${RED}Файл правил не найден${NC}"
    fi
    echo ""
    read -p "Нажмите Enter..."
}

# --- СОЗДАНИЕ СЛУЖБЫ SYSTEMD ---
create_systemd_service() {
    echo -e "\n${CYAN}--- Создание службы systemd для автозагрузки ---${NC}"
    
    SERVICE_FILE="/etc/systemd/system/load-iptables-rules.service"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Load Custom iptables Rules After Network Up
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $RULES_FILE
ExecStop=/bin/bash -c "iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -t nat -F && iptables -F"
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable load-iptables-rules.service
    
    echo -e "${GREEN}[OK] Служба создана и включена${NC}"
    echo -e "${YELLOW}[INFO] Перезагрузите систему для проверки автозагрузки${NC}"
    read -p "Нажмите Enter..."
}

# --- МЕНЮ ---
show_menu() {
    while true; do
        clear
        show_banner
        
        echo -e "${CYAN}Файл правил: $RULES_FILE${NC}"
        echo -e "${CYAN}Резервная копия: $BACKUP_FILE${NC}"
        echo -e "------------------------------------------------------"
        
        echo -e "1) Настроить ${GREEN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${GREEN}VLESS / XRay${NC} (TCP)"
        echo -e "3) Посмотреть активные правила"
        echo -e "4) ${RED}Удалить одно правило${NC}"
        echo -e "5) ${RED}Сбросить ВСЕ настройки${NC}"
        echo -e "6) ${YELLOW}📚 ИНСТРУКЦИЯ (Как настроить)${NC}"
        echo -e "7) ${BLUE}Просмотреть файл правил${NC}"
        echo -e "8) ${GREEN}Перезагрузить правила из файла${NC}"
        echo -e "9) ${MAGENTA}Создать службу автозагрузки${NC}"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) list_active_rules ;;
            4) delete_single_rule ;;
            5) flush_rules ;;
            6) show_instructions ;;
            7) view_rules_file ;;
            8) load_iptables_rules ;;
            9) create_systemd_service ;;
            0) 
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *) 
                echo -e "${RED}Неверный выбор!${NC}"
                sleep 1
                ;;
        esac
    done
}

# --- ЗАПУСК ---
check_root
prepare_system
init_iptables_file
load_iptables_rules
show_menu
