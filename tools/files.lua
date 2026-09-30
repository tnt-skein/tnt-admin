--- Мелочи для работы с файлами в инструментах сборки.
---
--- Инструменты читают файлы одинаково, и одинаково же ошибаются: молча
--- получают nil вместо содержимого и падают через три строки в непонятном
--- месте. Здесь чтение одно на всех, и отказ называет файл.

local fio = require('fio')

local Module = {}

--- Читает файл целиком.
---@param path string
---@return string
function Module.read(path)
    local file, err = fio.open(path, { 'O_RDONLY' })

    if file == nil then
        error(('файл %s не открыт: %s'):format(path, tostring(err)))
    end

    local body = file:read()
    file:close()

    return body
end

--- Записывает файл целиком, заменяя прежнее содержимое.
---@param path string
---@param body string
function Module.write(path, body)
    local file, err = fio.open(path, { 'O_CREAT', 'O_WRONLY', 'O_TRUNC' }, tonumber('644', 8))

    if file == nil then
        error(('файл %s не открыт на запись: %s'):format(path, tostring(err)))
    end

    file:write(body)
    file:close()
end

--- Обычные файлы каталога по порядку.
---
--- Порядок нужен, чтобы собранное не зависело от того, как файлы легли
--- на диск: иначе один и тот же каталог даёт разные сборки.
---@param directory string
---@return string[]
function Module.list(directory)
    local names, err = fio.listdir(directory)

    if names == nil then
        error(('каталог %s не прочитан: %s'):format(directory, tostring(err)))
    end

    local found = {}

    for _, name in ipairs(names) do
        if fio.path.is_file(fio.pathjoin(directory, name)) then
            table.insert(found, name)
        end
    end

    table.sort(found)

    return found
end

return Module
