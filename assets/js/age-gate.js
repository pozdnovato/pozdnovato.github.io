// 18+ confirmation screen. Loaded synchronously in <head> (only on pages that
// carry the #age-gate markup) so a returning, already-confirmed visitor never
// sees the overlay flash: the .age-ok class is set before first paint.
(function () {
  var KEY = 'age-confirmed-18';
  var root = document.documentElement;

  function isConfirmed() {
    try {
      return localStorage.getItem(KEY) === '1';
    } catch (e) {
      return false;
    }
  }

  if (isConfirmed()) {
    root.classList.add('age-ok');
    return;
  }

  document.addEventListener('DOMContentLoaded', function () {
    var gate = document.getElementById('age-gate');
    if (!gate) return;

    var page = document.querySelector('.page');
    var yes = gate.querySelector('[data-age-yes]');
    var no = gate.querySelector('[data-age-no]');
    var question = gate.querySelector('[data-age-question]');
    var denied = gate.querySelector('[data-age-denied]');

    // Keep the page behind the overlay out of reach of keyboard and screen readers.
    if (page) page.setAttribute('inert', '');

    yes.addEventListener('click', function () {
      try {
        localStorage.setItem(KEY, '1');
      } catch (e) {}
      root.classList.add('age-ok');
      if (page) page.removeAttribute('inert');
    });

    no.addEventListener('click', function () {
      question.hidden = true;
      denied.hidden = false;
    });

    // Focusing inside DOMContentLoaded itself gets dropped; wait for first paint.
    requestAnimationFrame(function () {
      yes.focus();
    });
  });
})();
