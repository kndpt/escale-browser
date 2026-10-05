/*
An explicit main-frame localStorage read or mutation in the client world.
The panel token and URL prevent queued actions reaching a replacement document.
All values are bounded before crossing the bridge. Writes compare the original
value so a stale editor never silently overwrites an application's newer state.
*/
(function (args) {
  if (location.href !== args.url) throw new Error('The page changed. Reopen Site Data.');
  if (args.action === 'read') globalThis.__escaleStorageToken = args.token;
  if (globalThis.__escaleStorageToken !== args.token) throw new Error('The document changed. Reopen Site Data.');
  if (args.action === 'set' || args.action === 'delete') {
    if (localStorage.getItem(args.key) !== args.expected) throw new Error('This entry changed. Refresh before editing it.');
    if (args.action === 'set') localStorage.setItem(args.key, args.value);
    else localStorage.removeItem(args.key);
  } else if (args.action === 'clear') {
    for (const entry of args.entries) {
      if (localStorage.getItem(entry.key) !== entry.value) throw new Error('Entries changed. Refresh before clearing.');
    }
    for (const entry of args.entries) localStorage.removeItem(entry.key);
  }
  if (localStorage.length > 2000) throw new Error('More than 2,000 entries. Use Web Inspector.');
  const entries = []; let size = 0;
  const encoder = new TextEncoder();
  for (let index = 0; index < localStorage.length; index++) {
    const key = localStorage.key(index), value = localStorage.getItem(key);
    if (key.length + value.length > 1048576) throw new Error('localStorage exceeds the 1 MiB preview limit. Use Web Inspector.');
    size += encoder.encode(key).length + encoder.encode(value).length;
    if (size > 1048576) throw new Error('localStorage exceeds the 1 MiB preview limit. Use Web Inspector.');
    entries.push({key, value});
  }
  return entries.sort((a, b) => a.key.localeCompare(b.key));
})
