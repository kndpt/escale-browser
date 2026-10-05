/*
Extension user scripts are guarded by their URL globs and run in their requested world.
Swift inserts encoded globs and the extension-owned source into the four marked slots.
*/
/* Escale: a user script (chrome.userScripts) */
escale_user_script: {
  const __escaleHref = location.href;
  const __escaleGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
  const __escaleIn = __ESCALE_INCLUDE__, __escaleOut = __ESCALE_EXCLUDE__;
  if ((__escaleIn.length && !__escaleIn.some((g) => __escaleGlob(g).test(__escaleHref))) || __escaleOut.some((g) => __escaleGlob(g).test(__escaleHref))) break escale_user_script;
__ESCALE_PRELUDE__
__ESCALE_CODE__
}
