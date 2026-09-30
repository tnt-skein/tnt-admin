{{-- Полоска занятой памяти с подписью.

     Поля: `ratio` — доля от нуля до единицы. --}}
<div class="d-flex align-items-center gap-2">
    <div class="progress memory-bar flex-grow-1" role="img"
         aria-label="память {{ format.percent(ratio) }}">
        <div class="progress-bar bg-{{ format.memory_tone(ratio) }}" style="width: {{ format.width(ratio) }}%"></div>
    </div>
    <span class="small text-body-secondary text-nowrap">{{ format.percent(ratio) }}</span>
</div>
