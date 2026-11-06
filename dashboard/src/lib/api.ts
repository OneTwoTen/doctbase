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

export class ApiClient {
  private baseUrl: string;
  private token: string | null = null;

  constructor(baseUrl: string = '/api/v1') {
    this.baseUrl = baseUrl;
  }

  setToken(token: string | null) {
    this.token = token;
  }

  private async request<T>(path: string, options: RequestInit = {}): Promise<T> {
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      ...(options.headers as Record<string, string> || {}),
    };

    if (this.token) {
      headers['Authorization'] = `Bearer ${this.token}`;
    }

    const response = await fetch(`${this.baseUrl}${path}`, {
      ...options,
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

    return response.json();
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
