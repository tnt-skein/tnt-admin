{{-- Место, где ничего нет: пустой список объясняет, почему он пуст.

     Поля: `message` — что именно пусто, `hint` — почему. --}}
<div class="text-center text-body-secondary py-5">
    <p class="mb-1">{{ message }}</p>
    @if (hint ~= nil)
    <p class="small mb-0">{{ hint }}</p>
    @endif
</div>
