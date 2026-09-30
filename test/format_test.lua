--- Тесты слов и цветов панели: одно и то же должно выглядеть одинаково
--- на всех её страницах.
---
--- Цвет здесь — часть ответа «что с узлом», а не оформление: «не
--- отвечает» обязано быть красным и на обзоре, и в списке узлов.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.support.format')

---@type any
local format

g.before_each(function()
    format = helper.load('tnt.admin.app.support.format')
end)

g.after_each(function()
    helper.unload()
end)

g.test_a_share_is_shown_as_percent = function()
    t.assert_equals(format.percent(0.734), '73 %')
    t.assert_equals(format.percent(1), '100 %')
    -- Округление к ближайшему: 0.5 % не должны пропадать вниз.
    t.assert_equals(format.percent(0.005), '1 %')
    t.assert_equals(format.percent(nil), '—')
end

g.test_the_width_of_the_bar_stays_within_the_bar = function()
    -- Доля приходит из снимка чужого узла, и она бывает какой угодно:
    -- полоска шире ста процентов вылезла бы за карточку.
    t.assert_equals(format.width(0.734), '73.4')
    t.assert_equals(format.width(1.5), '100.0')
    t.assert_equals(format.width(-1), '0.0')
    t.assert_equals(format.width(nil), '0')
end

g.test_the_colour_of_memory_follows_its_steps = function()
    t.assert_equals(format.memory_tone(0.5), 'success')
    -- Порог — это граница, а не точка: занятая память растёт, и цвет
    -- обязан держаться за ней, а не вспыхивать на одном значении.
    t.assert_equals(format.memory_tone(format.MEMORY_STEPS.warning), 'warning')
    t.assert_equals(format.memory_tone(0.8), 'warning')
    t.assert_equals(format.memory_tone(format.MEMORY_STEPS.danger), 'danger')
    t.assert_equals(format.memory_tone(0.99), 'danger')
    -- Память неизвестна: серое — это «не знаем», а не «всё хорошо».
    t.assert_equals(format.memory_tone(nil), 'secondary')
end

g.test_duration_is_said_in_words = function()
    t.assert_equals(format.duration(90000), '1 д 1 ч')
    t.assert_equals(format.duration(3700), '1 ч 1 мин')
    t.assert_equals(format.duration(120), '2 мин')
    t.assert_equals(format.duration(5), '5 с')
    t.assert_equals(format.duration(-1), '—')
    t.assert_equals(format.duration(nil), '—')
end

g.test_the_borders_of_the_words_are_the_borders_of_the_clock = function()
    -- Сутки, час и минута считаются от настоящих секунд: сдвиг границы
    -- на секунду показал бы «0 д 24 ч» и «59 мин» вместо часа — а узел,
    -- поднятый сутки назад, дежурный узнаёт именно по этим словам.
    t.assert_equals(format.duration(86399), '23 ч 59 мин')
    t.assert_equals(format.duration(86400), '1 д 0 ч')
    t.assert_equals(format.duration(3599), '59 мин')
    t.assert_equals(format.duration(3600), '1 ч 0 мин')
    t.assert_equals(format.duration(59), '59 с')
    t.assert_equals(format.duration(60), '1 мин')
end

g.test_the_age_is_counted_from_the_clock_of_the_panel = function()
    -- Время панель берёт у часов страницы, а не у `os`: иначе две
    -- строки одной страницы расходились бы на секунду.
    t.assert_equals(format.since(1000, 1300), '5 мин назад')
    -- Миг из будущего — рассинхронизация часов узлов, а не «минус час».
    t.assert_equals(format.since(2000, 1000), '0 с назад')
    t.assert_equals(format.since(nil, 1000), '—')
end

g.test_time_and_moment_are_told_apart = function()
    -- В заголовке — время дня: панель обновляется часто, и дата там
    -- только мешает. В журнале аудита дата нужна.
    local stamp = os.time({ year = 2026, month = 9, day = 22, hour = 13, min = 5, sec = 7 })

    t.assert_equals(format.clock(stamp), '13:05:07')
    t.assert_equals(format.moment(stamp), '22.09.2026 13:05:07')
    t.assert_equals(format.clock(nil), '—')
    t.assert_equals(format.moment(nil), '—')
end

g.test_the_state_of_a_node_is_said_in_russian = function()
    t.assert_equals(format.state('running'), 'работает')
    t.assert_equals(format.state('orphan'), 'без лидера')
    -- Состояние, которого панель не знает, показывается как есть:
    -- дежурному важнее увидеть чужое слово, чем «неизвестно».
    t.assert_equals(format.state('шатается'), 'шатается')
    t.assert_equals(format.state(nil), 'неизвестно')
end

g.test_the_colour_of_the_state_says_what_is_wrong = function()
    t.assert_equals(format.state_tone({ reachable = true, status = 'running' }), 'success')
    t.assert_equals(format.state_tone({ reachable = false, status = 'running' }), 'danger')
    t.assert_equals(format.state_tone({ reachable = true, status = 'orphan' }), 'warning')
    t.assert_equals(format.state_tone({ reachable = true, status = 'unconfigured' }), 'warning')
    t.assert_equals(format.state_tone({ reachable = true, status = 'loading' }), 'info')
    -- Выведенный узел не «сломан»: он выведен, и красным его показывать
    -- значит звать дежурного к тому, что сделали нарочно.
    t.assert_equals(format.state_tone({ retired = true, reachable = false }), 'secondary')
end

g.test_the_level_of_a_finding_is_said_and_coloured = function()
    t.assert_equals({ format.level('critical'), format.level_tone('critical') }, { 'важно', 'danger' })
    t.assert_equals({ format.level('warning'), format.level_tone('warning') }, { 'внимание', 'warning' })
    t.assert_equals({ format.level('info'), format.level_tone('info') }, { 'к сведению', 'info' })
    t.assert_equals(format.level('шум'), 'шум')
    t.assert_equals(format.level(nil), 'к сведению')
    t.assert_equals(format.level_tone(nil), 'info')
end

g.test_an_action_is_named_in_words = function()
    t.assert_equals(format.action('reload_config'), 'перечитать конфигурацию')
    -- Снимок и копия — разные действия, и назвать их одним словом значит
    -- дать оператору нажать не то: снимок остаётся рядом с данными,
    -- копия уезжает в своё место и из неё поднимают узел.
    t.assert_equals(format.action('maintenance_snapshot'), 'снять снимок')
    t.assert_equals(format.action('maintenance_backup'), 'снять копию')
    -- Действие, которого панель не знает, приходит от кластера: показать
    -- его имя честнее, чем слово «действие».
    t.assert_equals(format.action('teleport'), 'teleport')
    t.assert_equals(format.action(nil), 'действие')
end
