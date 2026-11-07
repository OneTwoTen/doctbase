export interface ProblemDetails {
  type: string;
  title: string;
  status: number;
  detail?: string;
  instance?: string;
  code: string;
  request_id?: string;
  docs_url?: string;
}

export interface ServiceRuntimeState {
  name: string;
  state: string;
  health: 'ok' | 'warn' | 'error' | 'unknown';
  version?: string;
  source: string;
  optional: boolean;
  unit?: string;
  endpoint?: string;
  last_error?: string;
  last_check_at?: number;
}

export interface ServicesResponse {
  items: ServiceRuntimeState[];
}

export type UserRole = 'owner' | 'admin' | 'viewer';

export interface AdminUser {
  id: string;
  email: string;
  role: UserRole;
}

export interface SessionResponse {
  admin: AdminUser;
  expires_at: number;
}

export type LoginResponse = SessionResponse;

const CSRF_COOKIE = 'doctbase_csrf';

function readCookie(name: string): string | null {
  const prefix = `${name}=`;
  for (const part of document.cookie.split(';')) {
    const value = part.trim();
    if (value.startsWith(prefix)) {
      return decodeURIComponent(value.slice(prefix.length));
    }
  }
  return null;
}

export class ApiClient {
  private baseUrl: string;

  constructor(baseUrl: string = '/api/v1') {
    this.baseUrl = baseUrl;
  }

  private csrf(): string | null {
    return readCookie(CSRF_COOKIE);
  }

  private async request<T>(path: string, options: RequestInit = {}): Promise<T> {
    const method = (options.method ?? 'GET').toUpperCase();
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      ...(options.headers as Record<string, string> || {}),
    };

    if (method !== 'GET' && method !== 'HEAD' && method !== 'OPTIONS') {
      const csrfToken = this.csrf();
      if (csrfToken) headers['X-CSRF-Token'] = csrfToken;
    }

    const response = await fetch(`${this.baseUrl}${path}`, {
      ...options,
      credentials: 'same-origin',
      headers,
    });

    if (!response.ok) {
      const errorJson: ProblemDetails = await response.json().catch(() => ({
        type: 'about:blank',
        title: response.statusText,
        status: response.status,
        code: 'HTTP_ERROR',
      }));
      throw errorJson;
    }

    if (response.status === 204) return undefined as T;
    return response.json();
  }

  async login(email: string, password: string): Promise<LoginResponse> {
    return this.request<LoginResponse>('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
  }

  async logout(): Promise<void> {
    await this.request<void>('/auth/logout', { method: 'POST' });
  }

  async getSession(): Promise<SessionResponse> {
    return this.request<SessionResponse>('/auth/session');
  }

  async getServices(): Promise<ServicesResponse> {
    return this.request<ServicesResponse>('/services');
  }

  async getService(name: string): Promise<ServiceRuntimeState> {
    return this.request<ServiceRuntimeState>(`/services/${name}`);
  }

  async restartService(name: string): Promise<{ ok: boolean; target: string }> {
    return this.request<{ ok: boolean; target: string }>(`/services/${name}/restart`, {
      method: 'POST',
    });
  }
}

export const api = new ApiClient();
