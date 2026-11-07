import { writable } from 'svelte/store';
import { api, type SessionResponse, type UserRole } from './api';

export type { UserRole };

export interface UserSession {
  userId: string;
  email: string | null;
  role: UserRole;
  expiresAt: number;
}

function toSession(response: SessionResponse): UserSession {
  return {
    userId: response.admin.id,
    email: response.admin.email,
    role: response.admin.role,
    expiresAt: response.expires_at,
  };
}

function createAuthStore() {
  const { subscribe, set } = writable<UserSession | null>(null);

  return {
    subscribe,
    async login(email: string, password: string) {
      const response = await api.login(email, password);
      set(toSession(response));
    },
    async logout() {
      try {
        await api.logout();
      } finally {
        set(null);
      }
    },
    async restore() {
      try {
        set(toSession(await api.getSession()));
      } catch {
        set(null);
      }
    },
    clear() {
      set(null);
    },
  };
}

export const auth = createAuthStore();
