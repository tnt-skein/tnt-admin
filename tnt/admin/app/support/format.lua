--- Как панель пишет числа, время и состояния.
---
--- Всё в одном месте: одна и та же длительность не должна выглядеть
--- на обзоре иначе, чем в списке узлов, а состояние узла — зваться
--- по-разному на двух страницах.
---
--- Здесь же цвета: имя цвета Bootstrap — это часть ответа на вопрос
--- «что с узлом», а не оформление. Страница ставит класс, а решает
--- модуль — иначе «не отвечает» на одной странице красное, а на другой
--- серое.

local Module = {}

--- Пороги доли памяти: до первого — спокойно, до второго — внимание.
Module.MEMORY_STEPS = { warning = 0.7, danger = 0.85 }

--- Доля как проценты.
---@param ratio number|nil
---@return string
function Module.percent(ratio)
    if type(ratio) ~= 'number' then
        return '—'
    end

    return ('%d %%'):format(math.floor(ratio * 100 + 0.5))
end

--- Ширина полоски в процентах: число для стиля.
---@param ratio number|nil
---@return string
function Module.width(ratio)
    if type(ratio) ~= 'number' then
        return '0'
    end

    return ('%.1f'):format(math.max(0, math.min(1, ratio)) * 100)
end

--- Цвет полоски памяти по её заполненности.
---@param ratio number|nil
---@return string tone Имя цвета Bootstrap
function Module.memory_tone(ratio)
    if type(ratio) ~= 'number' then
        return 'secondary'
    end

    if ratio >= Module.MEMORY_STEPS.danger then
        return 'danger'
    end

    if ratio >= Module.MEMORY_STEPS.warning then
        return 'warning'
    end

    return 'success'
end

--- Длительность словами: часы и минуты, а не 86400 секунд.
---@param seconds number|nil
---@return string
function Module.duration(seconds)
    if type(seconds) ~= 'number' or seconds < 0 then
        return '—'
    end

    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)

    if days > 0 then
        return ('%d д %d ч'):format(days, hours)
    end

    if hours > 0 then
        return ('%d ч %d мин'):format(hours, minutes)
    end

    if minutes > 0 then
        return ('%d мин'):format(minutes)
    end

    return ('%d с'):format(math.floor(seconds))
end

--- Сколько прошло с мига: «4 мин назад».
---@param stamp number|nil Миг в секундах эпохи
---@param now number Нынешний миг: панель берёт его у часов, а не у os
---@return string
function Module.since(stamp, now)
    if type(stamp) ~= 'number' then
        return '—'
    end

    return ('%s назад'):format(Module.duration(math.max(0, now - stamp)))
end

--- Время дня: панель обновляется часто, и дата в заголовке только мешает.
---@param stamp number|nil
---@return string
function Module.clock(stamp)
    if type(stamp) ~= 'number' then
        return '—'
    end

    return os.date('%H:%M:%S', stamp)
end

--- Миг целиком: в журнале аудита важна дата, а не только время.
---@param stamp number|nil
---@return string
function Module.moment(stamp)
    if type(stamp) ~= 'number' then
        return '—'
    end

    return os.date('%d.%m.%Y %H:%M:%S', stamp)
end

--- Как зовётся состояние узла по-русски.
Module.STATES = {
    running = 'работает',
    loading = 'загружается',
    orphan = 'без лидера',
    hot_standby = 'ждёт своей очереди',
    unconfigured = 'не настроен',
    unreachable = 'не отвечает',
    unknown = 'неизвестно',
}

--- Состояние узла словами.
---@param status string|nil
---@return string
function Module.state(status)
    return Module.STATES[status] or status or 'неизвестно'
end

--- Цвет состояния узла.
---@param server table
---@return string tone Имя цвета Bootstrap
function Module.state_tone(server)
    if server.retired then
        return 'secondary'
    end

    if not server.reachable then
        return 'danger'
    end

    if server.status == 'running' then
        return 'success'
    end

    if server.status == 'orphan' or server.status == 'unconfigured' then
        return 'warning'
    end

    return 'info'
end

--- Как зовётся уровень находки.
Module.LEVELS = {
    critical = 'важно',
    warning = 'внимание',
    info = 'к сведению',
}

--- Уровень находки словами.
---@param level string|nil
---@return string
function Module.level(level)
    return Module.LEVELS[level] or level or 'к сведению'
end

--- Цвет уровня находки.
---@param level string|nil
---@return string tone Имя цвета Bootstrap
function Module.level_tone(level)
    if level == 'critical' then
        return 'danger'
    end

    if level == 'warning' then
        return 'warning'
    end

    return 'info'
end

--- Как зовутся действия над кластером.
Module.ACTIONS = {
    reload_config = 'перечитать конфигурацию',
    restart_replication = 'перезапустить репликацию',
    disable_server = 'вывести узел из работы',
    enable_server = 'вернуть узел в работу',
    promote = 'сделать лидером',
    force_promote = 'сделать лидером принудительно',
    enable_rebalancer = 'включить перебалансировку',
    refine_uri = 'исправить адрес узла',
    maintenance_snapshot = 'снять снимок',
    maintenance_backup = 'снять копию',
    maintenance_compact = 'уплотнить файлы',
    maintenance_purge = 'убрать старые файлы',
}

--- Действие словами.
---@param action string|nil
---@return string
function Module.action(action)
    return Module.ACTIONS[action] or action or 'действие'
end

return Module
