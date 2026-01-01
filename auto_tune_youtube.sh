#!/bin/bash

# ============================================
# Auto Tune Standalone для zapret
# Автоматический подбор стратегии для YouTube
# Работает из коробки - нужен только bash и curl
# ============================================

# Определяем директорию скрипта (работает при запуске из любого места)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/main_script.sh"
STOP_SCRIPT="$SCRIPT_DIR/stop_and_clean_nft.sh"
REPO_DIR="$SCRIPT_DIR/zapret-latest"
CUSTOM_DIR="$SCRIPT_DIR/custom-strategies"
CONF_FILE="$SCRIPT_DIR/conf.env"
RESULTS_FILE="$SCRIPT_DIR/auto_tune_youtube_results.txt"

# Время ожидания после запуска стратегии (секунды)
WAIT_TIME=2
# Таймаут для проверки YouTube (секунды)
CURL_TIMEOUT=3
# Пауза между попытками
ATTEMPT_DELAY=0.5
# Количество попыток (1 достаточно для TCP, проверяем размер ответа для надёжности)
ATTEMPTS=1
# Минимальный размер ответа в байтах (защита от ложно-положительных)
MIN_RESPONSE_SIZE=1000

# === Второй этап: проверка стабильности ===
# Жёсткий тест: полная очистка + тест 20 секунд + проверки каждые 5с
STAGE2_TIMEOUT=10       # Таймаут для каждого запроса (секунды)
STAGE2_MIN_SIZE=100000  # Минимальный размер ответа (~100KB)
STAGE2_TEST_DURATION=20 # Длительность теста стратегии (секунды)
STAGE2_INTERVAL=5       # Интервал между проверками (секунды)

#TODO: Добавить QUIC/HTTP3 проверку когда curl с HTTP/3 станет доступен
# Сейчас проверяем только TCP. Для QUIC нужен curl --http3 или httpx
# autottl используется только для UDP/QUIC, для TCP работает сразу

# Массив с именами файлов стратегий (заполняется в get_strategy_files)
declare -a STRATEGY_FILES=()

# Массив с рабочими стратегиями (номер:имя:yt_ok:cdn_ok)
declare -a WORKING_STRATEGIES=()

# Массив со стабильными стратегиями (прошедшие второй этап)
# Формат: номер:имя:успехов:всего_проверок
declare -a STABLE_STRATEGIES=()

# Счётчики
TESTED_COUNT=0
SUCCESS_COUNT=0
FAILED_COUNT=0

# ═══════════════════════════════════════════════════════════════
# Прогресс-бар
# ═══════════════════════════════════════════════════════════════
BAR_WIDTH=40
BAR_FILL="█"
BAR_EMPTY="░"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Рисует прогресс-бар
# $1 = текущее значение, $2 = максимум, $3 = цвет (опционально)
draw_progress_bar() {
    local current=$1
    local max=$2
    local color=${3:-$CYAN}
    
    local percent=$((current * 100 / max))
    local filled=$((current * BAR_WIDTH / max))
    local empty=$((BAR_WIDTH - filled))
    
    # Строим бар
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="$BAR_FILL"; done
    for ((i=0; i<empty; i++)); do bar+="$BAR_EMPTY"; done
    
    printf "\r  ${color}[%s]${NC} %3d%% (%d/%d)" "$bar" "$percent" "$current" "$max"
}

# Очищает строку прогресс-бара
clear_progress_line() {
    printf "\r%*s\r" 80 ""
}

# Спиннер для долгих операций
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPINNER_IDX=0

# Показывает следующий кадр спиннера
spin() {
    printf "\r  ${CYAN}${SPINNER_CHARS:SPINNER_IDX:1}${NC} %s" "$1"
    SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_CHARS} ))
}

# Функция получения списка файлов стратегий (как в main_script.sh)
# ВАЖНО: порядок должен совпадать с main_script.sh:
# 1. Сначала кастомные из custom-strategies/
# 2. Потом стандартные из zapret-latest/
get_strategy_files() {
    # Сначала кастомные стратегии (как в main_script.sh)
    if [[ -d "$CUSTOM_DIR" ]]; then
        for file in "$CUSTOM_DIR"/*.bat; do
            [[ -f "$file" ]] && STRATEGY_FILES+=("$(basename "$file")")
        done
    fi
    
    # Потом стандартные из репозитория
    if [[ -d "$REPO_DIR" ]]; then
        while IFS= read -r -d '' file; do
            STRATEGY_FILES+=("$(basename "$file")")
        done < <(find "$REPO_DIR" -maxdepth 1 -type f \( -name "general*.bat" -o -name "discord.bat" \) -print0)
    fi
}

# Функция подсчёта количества стратегий
count_strategies() {
    echo "${#STRATEGY_FILES[@]}"
}

# Функция получения имени файла стратегии по номеру (1-based)
get_strategy_name() {
    local num=$1
    local idx=$((num - 1))
    if [[ $idx -ge 0 && $idx -lt ${#STRATEGY_FILES[@]} ]]; then
        echo "${STRATEGY_FILES[$idx]}"
    else
        echo ""
    fi
}

# Функция получения пути к файлу стратегии
get_strategy_path() {
    local name=$1
    if [[ -f "$CUSTOM_DIR/$name" ]]; then
        echo "$CUSTOM_DIR/$name"
    elif [[ -f "$REPO_DIR/$name" ]]; then
        echo "$REPO_DIR/$name"
    else
        echo ""
    fi
}

# Примечание: --dpi-desync-repeats относится к UDP/QUIC, для TCP не используется
# Оставлено для возможного будущего использования при добавлении QUIC проверки

# Функция сохранения найденной стратегии в conf.env
save_config() {
    local strategy_name=$1
    
    if [[ -z "$strategy_name" ]]; then
        echo "⚠ Не удалось определить имя стратегии"
        return 1
    fi
    
    echo "Сохраняем стратегию в $CONF_FILE..."
    
    # Обновляем или создаём conf.env
    cat > "$CONF_FILE" << EOF
interface=any
gamefilter=false
strategy=$strategy_name
EOF
    
    echo "✓ Сохранено: strategy=$strategy_name"
    echo ""
    echo "Теперь можно запускать: ./main_script.sh -nointeractive"
}

# Загружаем список файлов стратегий
get_strategy_files

# Динамически определяем количество стратегий
MAX_STRATEGY=$(count_strategies)
#MAX_STRATEGY=5

# Если не удалось определить, используем дефолтное значение
[[ $MAX_STRATEGY -eq 0 ]] && MAX_STRATEGY=14

# Текущая стратегия
STRATEGY=1

# Подключение всегда "any" (первый вариант в списке)
CONNECTION=1

# Проверка youtube.com (возвращает 0=успех, 1=неудача)
# Проверяем HTTP код, размер И наличие ключевого слова (защита от ложно-положительных)
check_youtube_main() {
    local tmpfile=$(mktemp)
    local code
    local size
    local has_keyword
    
    code=$(curl -s --tlsv1.3 --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" \
        -o "$tmpfile" -w "%{http_code}" "https://www.youtube.com" 2>/dev/null)
    size=$(wc -c < "$tmpfile" 2>/dev/null || echo 0)
    
    # Проверяем наличие ключевого слова "youtube" (регистронезависимо)
    if grep -qi "youtube" "$tmpfile" 2>/dev/null; then
        has_keyword=1
    else
        has_keyword=0
    fi
    rm -f "$tmpfile"
    
    # Успех: HTTP 2xx/3xx И размер > MIN И содержит "youtube"
    if [[ "$code" =~ ^[23] ]] && [[ $size -gt $MIN_RESPONSE_SIZE ]] && [[ $has_keyword -eq 1 ]]; then
        return 0
    else
        return 1
    fi
}

# Проверка googlevideo.com CDN (возвращает 0=успех, 1=неудача)
check_youtube_cdn() {
    local code
    code=$(curl -s --tlsv1.3 --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" \
        -o /dev/null -w "%{http_code}" "https://redirector.googlevideo.com" 2>/dev/null)
    [[ "$code" != "000" ]] && return 0 || return 1
}

# Функция проверки доступности YouTube через curl (TLS 1.3)
# Параметр $1: "quiet" — без вывода
check_youtube() {
    local quiet=$1
    
    [[ "$quiet" != "quiet" ]] && echo "Проверяем YouTube (TLS 1.3):"
    
    [[ "$quiet" != "quiet" ]] && echo -n "  youtube.com... "
    if check_youtube_main; then
        [[ "$quiet" != "quiet" ]] && echo "✓"
    else
        [[ "$quiet" != "quiet" ]] && echo "✗"
        return 1
    fi
    
    [[ "$quiet" != "quiet" ]] && echo -n "  googlevideo.com (CDN)... "
    if check_youtube_cdn; then
        [[ "$quiet" != "quiet" ]] && echo "✓"
        return 0
    else
        [[ "$quiet" != "quiet" ]] && echo "✗"
        return 1
    fi
}

# Тестирование стратегии с несколькими попытками
# Возвращает: "yt_ok:cdn_ok" (количество успешных из ATTEMPTS)
test_strategy_attempts() {
    local yt_ok=0
    local cdn_ok=0
    
    for ((i=1; i<=ATTEMPTS; i++)); do
        echo -n "  Попытка $i/$ATTEMPTS: " >&2
        
        local yt_result="✗"
        local cdn_result="✗"
        
        if check_youtube_main; then
            ((yt_ok++))
            yt_result="✓"
            
            # CDN проверяем только если основной доступен
            if check_youtube_cdn; then
                ((cdn_ok++))
                cdn_result="✓"
            fi
        fi
        
        echo "YT=$yt_result CDN=$cdn_result" >&2
        
        # Пауза между попытками (даёт zapret время на подбор TTL)
        [[ $i -lt $ATTEMPTS ]] && sleep "$ATTEMPT_DELAY"
    done
    
    # Только это попадёт в результат
    echo "$yt_ok:$cdn_ok"
}

# Функция вывода результатов тестирования (на экран и в файл)
show_results() {
    local stable_count=${#STABLE_STRATEGIES[@]}
    
    # Формируем результаты
    local header="
╔════════════════════════════════════════════════════════════╗
║                    РЕЗУЛЬТАТЫ ТЕСТА                        ║
╚════════════════════════════════════════════════════════════╝

Дата: $(date '+%Y-%m-%d %H:%M:%S')
Протестировано: $TESTED_COUNT из $MAX_STRATEGY
Проверка: TCP (TLS 1.3)

═══ ЭТАП 1: Быстрая проверка ═══
✓ Работают:     $SUCCESS_COUNT
✗ Не работают:  $FAILED_COUNT

═══ ЭТАП 2: Жёсткий тест (${STAGE2_TEST_DURATION}с, проверки каждые ${STAGE2_INTERVAL}с) ═══
✓ Стабильные:   $stable_count
"
    
    # Выводим на экран
    echo "$header"
    
    # Записываем в файл (перезаписываем)
    echo "$header" > "$RESULTS_FILE"
    
    if [[ $SUCCESS_COUNT -eq 0 ]]; then
        echo "❌ Ни одна стратегия не сработала на первом этапе."
        echo "❌ Ни одна стратегия не сработала на первом этапе." >> "$RESULTS_FILE"
        return 1
    fi
    
    # === Таблица 1: Прошедшие первый этап ===
    local table1="
────────────────────────────────────────────────────────────────
ТАБЛИЦА 1: Прошедшие быструю проверку (этап 1)
────────────────────────────────────────────────────────────────"
    echo "$table1"
    echo "$table1" >> "$RESULTS_FILE"
    
    printf "  %-4s %-40s %s\n" "№" "Стратегия" "YT/CDN"
    printf "  %-4s %-40s %s\n" "№" "Стратегия" "YT/CDN" >> "$RESULTS_FILE"
    
    echo "────────────────────────────────────────────────────────────────"
    echo "────────────────────────────────────────────────────────────────" >> "$RESULTS_FILE"
    
    for entry in "${WORKING_STRATEGIES[@]}"; do
        local num="${entry%%:*}"
        local rest="${entry#*:}"
        local name="${rest%%:*}"
        rest="${rest#*:}"
        local yt_ok="${rest%%:*}"
        rest="${rest#*:}"
        local cdn_ok="${rest%%:*}"
        
        local line
        line=$(printf "  [%-2s] %-40s YT:✓ CDN:%s" "$num" "$name" "$( [[ $cdn_ok -gt 0 ]] && echo '✓' || echo '✗' )")
        echo "$line"
        echo "$line" >> "$RESULTS_FILE"
    done
    
    echo "────────────────────────────────────────────────────────────────"
    echo "────────────────────────────────────────────────────────────────" >> "$RESULTS_FILE"
    
    # === Таблица 2: Прошедшие второй этап (стабильные) ===
    if [[ $stable_count -gt 0 ]]; then
        local table2="
────────────────────────────────────────────────────────────────
ТАБЛИЦА 2: ✓ Стабильные стратегии (прошли жёсткий тест)
────────────────────────────────────────────────────────────────"
        echo "$table2"
        echo "$table2" >> "$RESULTS_FILE"
        
        printf "  %-4s %-40s %s\n" "№" "Стратегия" "Результат"
        printf "  %-4s %-40s %s\n" "№" "Стратегия" "Результат" >> "$RESULTS_FILE"
        
        echo "────────────────────────────────────────────────────────────────"
        echo "────────────────────────────────────────────────────────────────" >> "$RESULTS_FILE"
        
        for entry in "${STABLE_STRATEGIES[@]}"; do
            local num="${entry%%:*}"
            local rest="${entry#*:}"
            local name="${rest%%:*}"
            rest="${rest#*:}"
            local success="${rest%%:*}"
            local total="${rest#*:}"
            
            local line
            line=$(printf "  [%-2s] %-40s %d/%d (100%%)" "$num" "$name" "$success" "$total")
            echo "$line"
            echo "$line" >> "$RESULTS_FILE"
        done
        
        echo "────────────────────────────────────────────────────────────────"
        echo "────────────────────────────────────────────────────────────────" >> "$RESULTS_FILE"
    else
        echo ""
        echo "⚠️  Ни одна стратегия не прошла тест стабильности."
        echo "" >> "$RESULTS_FILE"
        echo "⚠️  Ни одна стратегия не прошла тест стабильности." >> "$RESULTS_FILE"
    fi
    
    echo ""
    echo "" >> "$RESULTS_FILE"
    echo "Результаты сохранены в: $RESULTS_FILE"
    return 0
}

# Извлечь имя стратегии из записи (формат: номер:имя:yt_ok:cdn_ok)
get_name_from_entry() {
    local entry=$1
    local rest="${entry#*:}"
    echo "${rest%%:*}"
}

# Извлечь номер стратегии из записи
get_num_from_entry() {
    local entry=$1
    echo "${entry%%:*}"
}

# === ЭТАП 2: Тест стабильности ===
# Жёсткий тест: фиксированное количество проверок с паузами между ними
# Возвращает: "успехов:всего:общий_размер" 
test_stability() {
    local spin_chars="⣾⣽⣻⢿⡿⣟⣯⣷"
    local spin_idx=0
    local success_count=0
    local total_size=0
    local total_checks=$((STAGE2_TEST_DURATION / STAGE2_INTERVAL))
    
    printf "\n" >&2
    
    for ((check_num=1; check_num<=total_checks; check_num++)); do
        printf "  ${CYAN}[%d/%d]${NC} Проверка... " "$check_num" "$total_checks" >&2
        
        # Делаем запрос
        local tmpfile=$(mktemp)
        local code=$(curl -s --tlsv1.3 \
            --connect-timeout 5 \
            --max-time "$STAGE2_TIMEOUT" \
            -o "$tmpfile" \
            -w "%{http_code}" \
            "https://www.youtube.com" 2>/dev/null)
        
        local size=$(wc -c < "$tmpfile" 2>/dev/null || echo 0)
        local has_keyword=0
        grep -qi "youtube" "$tmpfile" 2>/dev/null && has_keyword=1
        rm -f "$tmpfile"
        
        # Проверяем результат
        if [[ "$code" =~ ^[23] ]] && [[ $size -gt $STAGE2_MIN_SIZE ]] && [[ $has_keyword -eq 1 ]]; then
            ((success_count++))
            ((total_size += size))
            local size_kb=$((size / 1024))
            printf "${GREEN}✓${NC} ${size_kb}KB\n" >&2
        else
            printf "${RED}✗${NC} (код:$code, размер:$size)\n" >&2
        fi
        
        # Пауза перед следующей проверкой (кроме последней)
        if [[ $check_num -lt $total_checks ]]; then
            # Спиннер во время паузы
            for ((p=STAGE2_INTERVAL; p>0; p--)); do
                printf "\r  ${YELLOW}${spin_chars:spin_idx:1}${NC} Пауза ${p}с... " >&2
                spin_idx=$(( (spin_idx + 1) % ${#spin_chars} ))
                sleep 1
            done
            printf "\r%50s\r" "" >&2
        fi
    done
    
    echo "$success_count:$total_checks:$total_size"
}

# Функция выбора и сохранения стратегии
# Приоритет: стабильные (этап 2) > работающие (этап 1)
choose_and_save() {
    local stable_count=${#STABLE_STRATEGIES[@]}
    
    # Выбираем из какого массива предлагать
    local -n strategies_ref
    local source_name
    
    if [[ $stable_count -gt 0 ]]; then
        strategies_ref=STABLE_STRATEGIES
        source_name="стабильных (этап 2)"
    elif [[ $SUCCESS_COUNT -gt 0 ]]; then
        strategies_ref=WORKING_STRATEGIES
        source_name="рабочих (этап 1)"
        echo "⚠️  Нет стабильных стратегий, выбираем из прошедших первый этап."
    else
        echo "❌ Нет рабочих стратегий."
        return 1
    fi
    
    local count=${#strategies_ref[@]}
    
    # Если только одна — предлагаем её
    if [[ $count -eq 1 ]]; then
        local entry="${strategies_ref[0]}"
        local num=$(get_num_from_entry "$entry")
        local name=$(get_name_from_entry "$entry")
        
        echo "Найдена 1 стратегия из $source_name: [$num] $name"
        echo ""
        read -p "Сохранить в conf.env? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            save_config "$name"
        else
            echo "Отменено."
        fi
    else
        # Несколько — даём выбрать
        echo "Выберите стратегию из $source_name для сохранения (введите номер):"
        echo "(или Enter для лучшей по результатам, 0 для отмены)"
        echo ""
        read -p "Номер стратегии: " choice
        
        if [[ -z "$choice" ]]; then
            # Enter — берём первую (лучшую по проценту успеха)
            local entry="${strategies_ref[0]}"
            local name=$(get_name_from_entry "$entry")
            save_config "$name"
        elif [[ "$choice" == "0" ]]; then
            echo "Отменено."
        else
            # Ищем выбранную стратегию
            local found=false
            for entry in "${strategies_ref[@]}"; do
                local num=$(get_num_from_entry "$entry")
                if [[ "$num" == "$choice" ]]; then
                    local name=$(get_name_from_entry "$entry")
                    save_config "$name"
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                echo "❌ Стратегия #$choice не найдена среди $source_name."
            fi
        fi
    fi
}

# Функция для остановки текущей стратегии zapret
stop_zapret() {
    sudo "$STOP_SCRIPT" 2>/dev/null
    sleep 1
}

# Агрессивная очистка для второго этапа
deep_clean() {
    # Останавливаем zapret
    sudo "$STOP_SCRIPT" 2>/dev/null
    
    # Убиваем все процессы nfqws
    sudo pkill -9 nfqws 2>/dev/null
    
    # Очищаем nftables полностью
    sudo nft flush ruleset 2>/dev/null
    
    # Сбрасываем DNS кэш системы
    sudo systemd-resolve --flush-caches 2>/dev/null
    sudo resolvectl flush-caches 2>/dev/null
    
    # Сбрасываем conntrack (отслеживание соединений)
    sudo conntrack -F 2>/dev/null
    
    # Пауза для применения
    sleep 2
}

# Функция для запуска main_script.sh с параметрами
run_main_script() {
    local strategy=$1
    echo "Запуск: main_script.sh (стратегия=$strategy, подключение=any)"
    # Передаём ответы на интерактивные вопросы через stdin
    # y - подтверждение, strategy - номер стратегии, 1 - "any" (первый в списке интерфейсов)
    # Запускаем в фоне чтобы не блокировать скрипт
    printf "y\n%d\n%d\n" "$strategy" "$CONNECTION" | "$MAIN_SCRIPT" &
    # Даём время на запуск
    sleep "$WAIT_TIME"
    return 0
}

# ============================================
# Основная логика
# ============================================

echo ""
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║${NC}     ${BOLD}🔧 Auto Tune для zapret-youtube${NC}                        ${BOLD}${CYAN}║${NC}"
echo -e "${BOLD}${CYAN}║${NC}     ${CYAN}Автоматический подбор рабочей стратегии${NC}               ${BOLD}${CYAN}║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  📋 Найдено стратегий: ${BOLD}$MAX_STRATEGY${NC}"
echo -e "  🌐 Подключение: ${BOLD}any${NC} (все интерфейсы)"
echo ""

# Проверяем наличие curl
if ! command -v curl &> /dev/null; then
    echo "❌ Ошибка: curl не установлен. Установите: sudo apt install curl"
    exit 1
fi

# Проверяем наличие main_script.sh
if [[ ! -f "$MAIN_SCRIPT" ]]; then
    echo "❌ Ошибка: main_script.sh не найден в $SCRIPT_DIR"
    exit 1
fi

# Первая проверка — без zapret
echo "Проверяем доступность YouTube без zapret..."
if check_youtube; then
    echo ""
    echo "✓ YouTube уже доступен без zapret. Ничего делать не нужно."
    echo ""
    exit 0
fi

echo ""
echo "YouTube недоступен. Начинаем тестирование всех стратегий..."
echo ""

# Останавливаем zapret если уже запущен
stop_zapret

# ═══════════════════════════════════════════════════════════════
# ЭТАП 1: Быстрая проверка всех стратегий
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║${CYAN}          ЭТАП 1: Быстрая проверка стратегий                ${NC}${BOLD}║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

for ((STRATEGY=1; STRATEGY<=MAX_STRATEGY; STRATEGY++)); do
    local_name=$(get_strategy_name $STRATEGY)
    
    # Прогресс-бар
    draw_progress_bar $STRATEGY $MAX_STRATEGY $BLUE
    echo ""
    
    # Компактный вывод
    printf "  ${BOLD}[%2d]${NC} %-42s " "$STRATEGY" "$local_name"
    
    run_main_script $STRATEGY >/dev/null 2>&1
    ((TESTED_COUNT++))
    
    # Тестируем
    result=$(test_strategy_attempts 2>/dev/null)
    yt_ok="${result%%:*}"
    cdn_ok="${result#*:}"
    
    if [[ $yt_ok -gt 0 ]]; then
        echo -e "${GREEN}✓${NC}"
        ((SUCCESS_COUNT++))
        WORKING_STRATEGIES+=("$STRATEGY:$local_name:$yt_ok:$cdn_ok")
    else
        echo -e "${RED}✗${NC}"
        ((FAILED_COUNT++))
    fi
    
    # Останавливаем перед следующей
    stop_zapret >/dev/null 2>&1
done

# Финальный прогресс
echo ""
draw_progress_bar $MAX_STRATEGY $MAX_STRATEGY $GREEN
echo -e " ${GREEN}Завершено!${NC}"

# ═══════════════════════════════════════════════════════════════
# ЭТАП 2: Тест стабильности для прошедших первый этап
# ═══════════════════════════════════════════════════════════════
if [[ ${#WORKING_STRATEGIES[@]} -gt 0 ]]; then
    echo ""
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${YELLOW}   ЭТАП 2: Жёсткий тест (${STAGE2_TEST_DURATION}с, проверки каждые ${STAGE2_INTERVAL}с)         ${NC}${BOLD}║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Проверяем ${BOLD}${#WORKING_STRATEGIES[@]}${NC} стратегий из первого этапа..."
    echo ""
    
    stage2_current=0
    stage2_total=${#WORKING_STRATEGIES[@]}
    
    for entry in "${WORKING_STRATEGIES[@]}"; do
        ((stage2_current++))
        num=$(get_num_from_entry "$entry")
        name=$(get_name_from_entry "$entry")
        
        # Прогресс-бар
        draw_progress_bar $stage2_current $stage2_total $YELLOW
        echo ""
        
        echo -e "  ${BOLD}[$num]${NC} $name"
        
        # Останавливаем предыдущую стратегию
        stop_zapret >/dev/null 2>&1
        
        # Запускаем стратегию
        run_main_script "$num" >/dev/null 2>&1
        
        # Тестируем стабильность (несколько проверок в течение 20с)
        result=$(test_stability)
        success="${result%%:*}"
        rest="${result#*:}"
        total="${rest%%:*}"
        total_size="${rest#*:}"
        
        # Считаем процент успеха
        if [[ $total -gt 0 ]]; then
            percent=$((success * 100 / total))
        else
            percent=0
        fi
        
        # Стабильна если 100% проверок успешны
        if [[ $success -eq $total ]] && [[ $total -gt 0 ]]; then
            total_kb=$((total_size / 1024))
            echo -e "  ${GREEN}${BOLD}✓ СТАБИЛЬНА${NC} ($success/$total, ${total_kb}KB)"
            STABLE_STRATEGIES+=("$num:$name:$success:$total")
        else
            echo -e "  ${RED}✗ Нестабильна${NC} ($success/$total = $percent%)"
        fi
        
        stop_zapret >/dev/null 2>&1
    done
    
    # Финальный прогресс
    echo ""
    draw_progress_bar $stage2_total $stage2_total $GREEN
    echo -e " ${GREEN}Завершено!${NC}"
fi

# Показываем результаты
show_results

# Предлагаем выбрать и сохранить
if [[ $SUCCESS_COUNT -gt 0 ]]; then
    choose_and_save
    
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║         Тестирование завершено!        ║"
    echo "╚════════════════════════════════════════╝"
fi

echo ""
