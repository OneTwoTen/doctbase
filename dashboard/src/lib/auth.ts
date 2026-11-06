import { writable } from 'svelte/store';
import { api } from './api';

export type UserRole = 'owner' | 'admin' | 'developer' | 'viewer';

export interface UserSession {
  id: string;
  userId: string;
  role: UserRole;
  token: string;
  expiresAt: number;
}

function createAuthStore() {
  const { subscribe, set, update } = writable<UserSession | null>(null);

  return {
    subscribe,
    login(session: UserSession) {
      api.setToken(session.token);
      set(session);
    },
    logout() {
      api.setToken(null);
      set(null);
    },
    setRole(role: UserRole) {
      update((s) => s ? { ...s, role } : null);
    },
  };
}

export const auth = createAuthStore();
