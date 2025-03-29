<script setup>
import HeaderActions from './HeaderActions.vue';
import { computed } from 'vue';

const props = defineProps({
  avatarUrl: {
    type: String,
    default: '',
  },
  introHeading: {
    type: String,
    default: '',
  },
  introBody: {
    type: String,
    default: '',
  },
  showPopoutButton: {
    type: Boolean,
    default: false,
  },
});

const containerClasses = computed(() => [
  props.avatarUrl ? 'justify-between' : 'justify-end',
]);
</script>

<template>
  <header
    class="header-expanded pt-6 pb-4 px-5 relative box-border w-full bg-transparent"
  >
    <div class="flex items-start" :class="containerClasses">
      <img
        v-if="avatarUrl"
        class="h-12 rounded-full"
        :src="avatarUrl"
        alt="Avatar"
      />
      <HeaderActions
        :show-popout-button="showPopoutButton"
        :show-end-conversation-button="false"
      />
    </div>
    <h2
      v-dompurify-html="introHeading"
      class="z-50 flex flex-col flex-1 w-full rounded-md justify-end"
    />
    <p
      v-dompurify-html="introBody"
      class="text-lg leading-normal text-n-slate-11"
    />
  </header>
</template>
