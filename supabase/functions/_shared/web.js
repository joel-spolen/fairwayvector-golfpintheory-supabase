// Bounded Web streams only: no Node Buffer and no unbounded response.json().
export async function readText(body, limit, signal) {
  if (!body) throw new Error('Missing body');
  const reader = body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal?.addEventListener('abort', cancel, { once: true });
  const chunks = [];
  let size = 0;
  try {
    if (signal?.aborted) throw new Error('Aborted');
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new RangeError('Body too large');
      chunks.push(value);
    }
    if (signal?.aborted) throw new Error('Aborted');
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } finally {
    signal?.removeEventListener('abort', cancel);
    cancel();
    reader.releaseLock();
  }
}

export function cancelBody(response) {
  void response.body?.cancel().catch(() => {});
}

// Includes streaming/JSON decoding in the deadline, even when a fake fetch ignores abort.
export async function withDeadline(milliseconds, work) {
  const controller = new AbortController();
  let timer;
  const deadline = new Promise((resolve, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error('Request timed out')); }, milliseconds);
  });
  try { return await Promise.race([work(controller.signal), deadline]); }
  finally { clearTimeout(timer); controller.abort(); }
}