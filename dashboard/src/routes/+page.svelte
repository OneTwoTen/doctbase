<script lang="ts">
  import { onMount } from 'svelte';
  import { api, type ServiceRuntimeState } from '$lib/api';
  import { auth } from '$lib/auth';

  let services: ServiceRuntimeState[] = [];
  let loading = true;
  let errorMessage: string | null = null;

  async function loadServices() {
    loading = true;
    errorMessage = null;
    try {
      const res = await api.getServices();
      services = res.items;
    } catch (err: any) {
      errorMessage = err.detail || err.title || 'Failed to load services';
    } finally {
      loading = false;
    }
  }

  async function handleRestart(name: string) {
    try {
      await api.restartService(name);
      await loadServices();
    } catch (err: any) {
      alert(`Restart failed: ${err.detail || err.title || err.code || 'Error'}`);
    }
  }

  onMount(() => {
    loadServices();
  });
</script>

<main class="container">
  <header>
    <h1>Doctbase Dashboard</h1>
    {#if $auth}
      <span class="badge">{$auth.role}</span>
    {/if}
  </header>

  {#if errorMessage}
    <div class="alert error">
      {errorMessage}
    </div>
  {/if}

  {#if loading}
    <p>Loading services...</p>
  {:else}
    <table>
      <thead>
        <tr>
          <th>Service</th>
          <th>State</th>
          <th>Health</th>
          <th>Endpoint</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody>
        {#each services as svc}
          <tr>
            <td><strong>{svc.name}</strong></td>
            <td><span class="status status-{svc.state}">{svc.state}</span></td>
            <td><span class="health health-{svc.health}">{svc.health}</span></td>
            <td><code>{svc.endpoint || '-'}</code></td>
            <td>
              <button on:click={() => handleRestart(svc.name)}>Restart</button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  {/if}
</main>

<style>
  .container {
    max-width: 960px;
    margin: 0 auto;
    padding: 2rem;
    font-family: system-ui, sans-serif;
  }
  header {
    display: flex;
    align-items: center;
    gap: 1rem;
    margin-bottom: 2rem;
  }
  .badge {
    background: #e2e8f0;
    padding: 0.25rem 0.5rem;
    border-radius: 4px;
    font-size: 0.875rem;
  }
  .alert.error {
    background: #fee2e2;
    color: #991b1b;
    padding: 1rem;
    border-radius: 6px;
    margin-bottom: 1rem;
  }
  table {
    width: 100%;
    border-collapse: collapse;
  }
  th, td {
    padding: 0.75rem 1rem;
    text-align: left;
    border-bottom: 1px solid #e2e8f0;
  }
  .status-ready { color: #16a34a; }
  .status-stopped { color: #64748b; }
  .status-starting { color: #d97706; }
  .health-ok { color: #16a34a; font-weight: bold; }
  .health-warn { color: #d97706; }
  .health-error { color: #dc2626; font-weight: bold; }
  button {
    background: #0284c7;
    color: white;
    border: none;
    padding: 0.4rem 0.8rem;
    border-radius: 4px;
    cursor: pointer;
  }
  button:hover {
    background: #0369a1;
  }
</style>
