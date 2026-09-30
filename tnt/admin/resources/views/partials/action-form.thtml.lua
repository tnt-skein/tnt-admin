{{-- Кнопка действия: обычная форма, а не сценарий.

     Действие выполняется отправкой формы — панель работает и без
     сценариев. Подтверждение спрашивает браузер: между кнопкой
     и действием над кластером должен стоять хотя бы один вопрос.

     Поля: `suggestion` — подсказка с действием и узлами. --}}
<form method="post" action="/actions/run" class="d-inline"
      onsubmit="return confirm('{{ format.action(suggestion.action) }}: выполнить?')">
    <input type="hidden" name="action" value="{{ suggestion.action }}">
    <input type="hidden" name="targets" value="{{ table.concat(suggestion.targets or {}, ',') }}">
    <button class="btn btn-sm btn-outline-primary" type="submit">Выполнить</button>
</form>
