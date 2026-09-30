--- Что панель отвечает о кластере: формы `tnt-data` тел её ответов.
---
--- Эти тела собирает сама панель. Представление кластера, находки,
--- подсказки и возможности (`tnt.admin.app.domain.cluster`) обработчики
--- отдают выдачей формы: наружу уходят только объявленные поля, пустой
--- словарь — `{}`, пустой список — `[]`. Из тех же форм описание API
--- (`tnt.admin.app.http.openapi`) берёт схемы ответов, поэтому поле,
--- дописанное в представление и забытое в форме, не расходится
--- с описанием молча: проверки пакета сличают ответ с тем, что собрала
--- модель, и видят пропажу. Узлы отбора обработчик собирает сам,
--- поле к полю, и что ответ проходит форму, проверяет его образец.
---
--- Значения выдача не проверяет: их приносит диагностика, и её слова
--- (уровень находки, состояние узла) панель не переименовывает.

local data = require('tnt.data')

local Module = {}

--- Заполненность памяти узла.
---@class ClusterMemory
---@field arena_ratio number|nil Занятая доля арены
---@field items_ratio number|nil Занятая доля места под кортежи
---@field quota_ratio number|nil Занятая доля квоты memtx

---@type TntDataShape<ClusterMemory>
local ClusterMemory = data.define({
    name = 'ClusterMemory',
    about = 'Заполненность памяти узла долями от 0 до 1',
    fields = {
        { 'arena_ratio', 'number', optional = true, about = 'Занятая доля арены' },
        {
            'items_ratio',
            'number',
            optional = true,
            about = 'Занятая доля места под кортежи',
        },
        { 'quota_ratio', 'number', optional = true, about = 'Занятая доля квоты memtx' },
    },
})

--- Конфигурация, применённая на узле.
---@class ServerConfig
---@field status string|nil Как узел применил конфигурацию
---@field fingerprint string|nil Отпечаток применённой конфигурации

---@type TntDataShape<ServerConfig>
local ServerConfig = data.define({
    name = 'ServerConfig',
    about = 'Конфигурация, применённая на узле',
    fields = {
        { 'status', 'string', optional = true, about = 'Как узел применил конфигурацию' },
        {
            'fingerprint',
            'string',
            optional = true,
            about = 'Отпечаток применённой конфигурации',
        },
    },
})

--- Узел кластера по снимку обхода.
---@class ClusterServer
---@field name string Имя узла
---@field replicaset string|nil Репликасет узла
---@field uri string|nil Адрес, который узел объявил соседям
---@field status string Состояние узла; unreachable — узел не ответил на обход
---@field reachable boolean Ответил ли узел на последний обход
---@field writable boolean Пишет ли узел на самом деле, а не по назначению
---@field message string|nil Почему узел не ответил
---@field last_seen number|nil Когда узел отвечал в последний раз, секунды эпохи
---@field uptime number|nil Сколько секунд узел работает
---@field version string|nil Версия Tarantool на узле
---@field lsn integer|nil Номер последней записи журнала узла
---@field clock number|nil Часы узла на момент обхода, секунды эпохи
---@field memory ClusterMemory Заполненность памяти
---@field config ServerConfig Применённая конфигурация
---@field lifecycle any|nil Жизненный цикл узла, если узел о нём сообщает
---@field retired any|nil Запись о выводе из эксплуатации; нет — узел в строю

---@type TntDataShape<ClusterServer>
local ClusterServer = data.define({
    name = 'ClusterServer',
    about = 'Узел кластера по снимку обхода',
    fields = {
        { 'name', 'string', about = 'Имя узла' },
        { 'replicaset', 'string', optional = true, about = 'Репликасет узла' },
        {
            'uri',
            'string',
            optional = true,
            about = 'Адрес, который узел объявил соседям',
        },
        {
            'status',
            'string',
            about = 'Состояние узла; unreachable — узел не ответил на обход',
        },
        { 'reachable', 'boolean', about = 'Ответил ли узел на последний обход' },
        {
            'writable',
            'boolean',
            about = 'Пишет ли узел на самом деле, а не по назначению',
        },
        { 'message', 'string', optional = true, about = 'Почему узел не ответил' },
        {
            'last_seen',
            'number',
            optional = true,
            about = 'Когда узел отвечал в последний раз, секунды эпохи',
        },
        { 'uptime', 'number', optional = true, about = 'Сколько секунд узел работает' },
        { 'version', 'string', optional = true, about = 'Версия Tarantool на узле' },
        {
            'lsn',
            'integer',
            optional = true,
            about = 'Номер последней записи журнала узла',
        },
        {
            'clock',
            'number',
            optional = true,
            about = 'Часы узла на момент обхода, секунды эпохи',
        },
        { 'memory', ClusterMemory, about = 'Заполненность памяти' },
        { 'config', ServerConfig, about = 'Применённая конфигурация' },
        {
            'lifecycle',
            'any',
            optional = true,
            about = 'Жизненный цикл узла, если узел о нём сообщает',
        },
        {
            'retired',
            'any',
            optional = true,
            about = 'Запись о выводе из эксплуатации; нет — узел в строю',
        },
    },
})

--- Репликасет: кого назначили и кто пишет на самом деле.
---@class ClusterReplicaset
---@field name string Имя репликасета
---@field servers string[]|nil Узлы репликасета
---@field leader string|nil Кого назначил координатор
---@field active_leader string|nil Кто пишет на самом деле: первый из писателей
---@field writers string[] Узлы, которые пишут; у здорового репликасета он один
---@field healthy boolean Пишет ли ровно один узел

---@type TntDataShape<ClusterReplicaset>
local ClusterReplicaset = data.define({
    name = 'ClusterReplicaset',
    about = 'Репликасет: кого назначили и кто пишет на самом деле',
    fields = {
        { 'name', 'string', about = 'Имя репликасета' },
        { 'servers', 'list', of = 'string', optional = true, about = 'Узлы репликасета' },
        { 'leader', 'string', optional = true, about = 'Кого назначил координатор' },
        {
            'active_leader',
            'string',
            optional = true,
            about = 'Кто пишет на самом деле: первый из писателей',
        },
        {
            'writers',
            'list',
            of = 'string',
            about = 'Узлы, которые пишут; у здорового репликасета он один',
        },
        { 'healthy', 'boolean', about = 'Пишет ли ровно один узел' },
    },
})

--- Сводка по кластеру.
---@class ClusterSummary
---@field total integer Узлов всего
---@field unreachable integer Сколько не ответило на обход
---@field retired integer Сколько выведено из эксплуатации
---@field replicasets integer Репликасетов всего

---@type TntDataShape<ClusterSummary>
local ClusterSummary = data.define({
    name = 'ClusterSummary',
    about = 'Сводка по кластеру',
    fields = {
        { 'total', 'integer', about = 'Узлов всего' },
        { 'unreachable', 'integer', about = 'Сколько не ответило на обход' },
        { 'retired', 'integer', about = 'Сколько выведено из эксплуатации' },
        { 'replicasets', 'integer', about = 'Репликасетов всего' },
    },
})

--- Представление кластера.
---@class Cluster
---@field version integer Версия представления: меняется, когда меняется смысл полей
---@field generation integer Номер обхода
---@field taken_at number|nil Когда снят снимок, секунды эпохи
---@field self_name string|nil Узел, который отвечает панели
---@field servers ClusterServer[] Узлы по имени
---@field replicasets ClusterReplicaset[] Репликасеты по имени
---@field summary ClusterSummary Сводка
---@field retired_read_at number|nil Когда список выведенных читался удачно в последний раз

---@type TntDataShape<Cluster>
local Cluster = data.define({
    name = 'Cluster',
    about = 'Представление кластера',
    fields = {
        {
            'version',
            'integer',
            about = 'Версия представления: меняется, когда меняется смысл полей',
        },
        { 'generation', 'integer', about = 'Номер обхода' },
        {
            'taken_at',
            'number',
            optional = true,
            about = 'Когда снят снимок, секунды эпохи',
        },
        { 'self_name', 'string', optional = true, about = 'Узел, который отвечает панели' },
        { 'servers', 'list', of = ClusterServer, about = 'Узлы по имени' },
        { 'replicasets', 'list', of = ClusterReplicaset, about = 'Репликасеты по имени' },
        { 'summary', ClusterSummary, about = 'Сводка' },
        {
            'retired_read_at',
            'number',
            optional = true,
            about = 'Когда список выведенных читался удачно в последний раз',
        },
    },
})

--- Находка диагностики.
---@class Issue
---@field id string Опознаватель находки: правило, область, узел
---@field rule string Правило диагностики
---@field level string Насколько серьёзно: warning либо critical
---@field scope string К чему относится: instance, replicaset либо cluster
---@field server string|nil Узел находки
---@field replicaset string|nil Репликасет находки
---@field message string Что не так, словами для человека

---@type TntDataShape<Issue>
local Issue = data.define({
    name = 'Issue',
    about = 'Находка диагностики',
    fields = {
        { 'id', 'string', about = 'Опознаватель находки: правило, область, узел' },
        { 'rule', 'string', about = 'Правило диагностики' },
        { 'level', 'string', about = 'Насколько серьёзно: warning либо critical' },
        { 'scope', 'string', about = 'К чему относится: instance, replicaset либо cluster' },
        { 'server', 'string', optional = true, about = 'Узел находки' },
        { 'replicaset', 'string', optional = true, about = 'Репликасет находки' },
        { 'message', 'string', about = 'Что не так, словами для человека' },
    },
})

--- Подсказка оператору.
---@class Suggestion
---@field action string Какое действие предлагается
---@field targets string[] Над какими узлами
---@field message string Что предлагается, словами для человека
---@field reasons string[] Находки, из-за которых предлагается

---@type TntDataShape<Suggestion>
local Suggestion = data.define({
    name = 'Suggestion',
    about = 'Подсказка оператору',
    fields = {
        { 'action', 'string', about = 'Какое действие предлагается' },
        { 'targets', 'list', of = 'string', about = 'Над какими узлами' },
        { 'message', 'string', about = 'Что предлагается, словами для человека' },
        {
            'reasons',
            'list',
            of = 'string',
            about = 'Находки, из-за которых предлагается',
        },
    },
})

--- Находки диагностики.
---@class Issues
---@field issues Issue[] Находки по порядку

---@type TntDataShape<Issues>
local Issues = data.define({
    name = 'Issues',
    about = 'Находки диагностики',
    fields = { { 'issues', 'list', of = Issue, about = 'Находки по порядку' } },
})

--- Подсказки оператору.
---@class Suggestions
---@field suggestions Suggestion[] Подсказки по порядку

---@type TntDataShape<Suggestions>
local Suggestions = data.define({
    name = 'Suggestions',
    about = 'Подсказки оператору',
    fields = { { 'suggestions', 'list', of = Suggestion, about = 'Подсказки по порядку' } },
})

--- Всё сразу и по одному снимку: то, что спрашивает страница обзора.
---@class Overview
---@field cluster Cluster Представление кластера
---@field issues Issue[] Находки
---@field suggestions Suggestion[] Подсказки

---@type TntDataShape<Overview>
local Overview = data.define({
    name = 'Overview',
    about = 'Кластер, находки и подсказки по одному снимку',
    fields = {
        { 'cluster', Cluster, about = 'Представление кластера' },
        { 'issues', 'list', of = Issue, about = 'Находки' },
        { 'suggestions', 'list', of = Suggestion, about = 'Подсказки' },
    },
})

--- Что умеет кластер под панелью.
---@class Capabilities
---@field version integer Версия представления
---@field failover boolean Есть ли внешний координатор смены лидера
---@field config_rollout boolean Умеет ли кластер раскатывать конфигурацию
---@field authenticated boolean Включён ли вход по паролю
---@field actions string[] Какие действия панель вправе предлагать

---@type TntDataShape<Capabilities>
local Capabilities = data.define({
    name = 'Capabilities',
    about = 'Что умеет кластер под панелью',
    fields = {
        { 'version', 'integer', about = 'Версия представления' },
        {
            'failover',
            'boolean',
            about = 'Есть ли внешний координатор смены лидера',
        },
        {
            'config_rollout',
            'boolean',
            about = 'Умеет ли кластер раскатывать конфигурацию',
        },
        { 'authenticated', 'boolean', about = 'Включён ли вход по паролю' },
        {
            'actions',
            'list',
            of = 'string',
            about = 'Какие действия панель вправе предлагать',
        },
    },
})

--- Узел, объявленный конфигурацией.
---@class ConfigInstance
---@field name string Имя узла
---@field replicaset_name string Репликасет
---@field group_name string Группа
---@field roles string[] Роли
---@field sharding_roles string[] Роли шардирования
---@field labels table<string, string> Метки

---@type TntDataShape<ConfigInstance>
local ConfigInstance = data.define({
    name = 'ConfigInstance',
    about = 'Узел, объявленный конфигурацией',
    fields = {
        { 'name', 'string', about = 'Имя узла' },
        { 'replicaset_name', 'string', about = 'Репликасет' },
        { 'group_name', 'string', about = 'Группа' },
        { 'roles', 'list', of = 'string', about = 'Роли' },
        { 'sharding_roles', 'list', of = 'string', about = 'Роли шардирования' },
        { 'labels', 'map', of = 'string', about = 'Метки' },
    },
})

--- Узлы конфигурации по отбору.
---@class ConfigInstances
---@field instances ConfigInstance[] Узлы по имени

---@type TntDataShape<ConfigInstances>
local ConfigInstances = data.define({
    name = 'ConfigInstances',
    about = 'Узлы конфигурации по отбору',
    fields = { { 'instances', 'list', of = ConfigInstance, about = 'Узлы по имени' } },
})

-- Формы по именам схем, вложенные тоже: их аннотации сверяют проверки
-- пакета, а описание API ссылается на них по имени.
Module.ClusterMemory = ClusterMemory
Module.ServerConfig = ServerConfig
Module.ClusterServer = ClusterServer
Module.ClusterReplicaset = ClusterReplicaset
Module.ClusterSummary = ClusterSummary
Module.Cluster = Cluster
Module.Issue = Issue
Module.Issues = Issues
Module.Suggestion = Suggestion
Module.Suggestions = Suggestions
Module.Overview = Overview
Module.Capabilities = Capabilities
Module.ConfigInstance = ConfigInstance
Module.ConfigInstances = ConfigInstances

return Module
