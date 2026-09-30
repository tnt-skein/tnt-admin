-- Конфигурация luacheck.

-- Базовый стандарт — LuaJIT: Tarantool исполняет код именно на нём.
std = 'luajit'

-- Глобалы, которые Tarantool добавляет к стандартной библиотеке.
read_globals = {
    'box',
    '_TARANTOOL',
    'tonumber64',
    'utf8',
    -- Tarantool дописывает в стандартные таблицы свои функции: их нет
    -- в обычном Lua, и без объявления luacheck считает их опечатками.
    table = { fields = { 'deepcopy', 'copy', 'clear', 'new', 'equals' } },
    string = { fields = { 'hex', 'fromhex' } },
    -- Поиск модуля загрузчиками Tarantool, с деревом `.rocks`: по нему
    -- панель находит каталог своей раскладки там, где её поставили.
    package = { fields = { 'search' } },
}

-- Поля 120 символов — та же планка, что в .editorconfig и stylua.toml.
max_line_length = 120

exclude_files = {
    '.rocks/**',
    'var/**',
    'node_modules/**',
    -- Собранная панель: стили и сценарий браузера, упакованные в модуль
    -- целью `make panel`. Это не рукописный код, и строка в нём одна
    -- на весь файл.
    'tnt/admin/public/bundle.lua',
    -- Шаблоны страниц: HTML с вкраплениями, не Lua.
    '**/*.thtml.lua',
    -- Временные файлы мутационного прогона.
    '.tmp_mutant.*',
    '**/*.um.backup.*',
}

files['test/*_test.lua'] = {
    -- luatest наполняет группу тестов присваиванием полей.
    std = '+busted',
}
