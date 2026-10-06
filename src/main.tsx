import React from 'react';
import ReactDOM from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { App } from './app/App';
import './styles.css';

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: 2, staleTime: 2_000, refetchOnWindowFocus: true } } });

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode><QueryClientProvider client={queryClient}><App /></QueryClientProvider></React.StrictMode>,
);
