document.addEventListener('DOMContentLoaded', function () {

  var lightbox = document.createElement('div');
  lightbox.className = 'lightbox';
  var lightboxImg = document.createElement('img');
  lightbox.appendChild(lightboxImg);
  document.body.appendChild(lightbox);

  function openLightbox(img) {
    lightboxImg.src = img.currentSrc || img.src;
    lightbox.classList.add('is-open');
  }

  function closeLightbox() {
    lightbox.classList.remove('is-open');
  }

  document.querySelectorAll('.case-image').forEach(function (img) {
    img.addEventListener('click', function () {
      openLightbox(img);
    });
  });

  lightbox.addEventListener('click', closeLightbox);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeLightbox();
  });

  var revealEls = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });

    revealEls.forEach(function (el) {
      observer.observe(el);
    });
  } else {
    revealEls.forEach(function (el) {
      el.classList.add('is-visible');
    });
  }

});
