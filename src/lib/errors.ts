export function messageOf(error: unknown) {
  if (error instanceof Error) return error.message;
  if (typeof error === 'object' && error && 'message' in error) return String(error.message);
  return 'Ada kendala sebentar. Coba lagi ya.';
}
