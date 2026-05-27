// Scroll-in reveals via IntersectionObserver. Single observer for all
// `.reveal` elements — once in viewport, they get the `.in` class and stop
// being watched.
(function () {
  const els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window)) {
    els.forEach(el => el.classList.add('in'));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -60px 0px' });
  els.forEach(el => io.observe(el));

  // Set copyright year
  const year = document.getElementById('year');
  if (year) year.textContent = new Date().getFullYear();

  // Parallax tilt on hero window — subtle, pointer-driven
  const heroArt = document.querySelector('.hero-art');
  const heroWindow = document.querySelector('.hero-window');
  if (heroArt && heroWindow && window.matchMedia('(pointer: fine)').matches) {
    heroArt.addEventListener('mousemove', (e) => {
      const rect = heroArt.getBoundingClientRect();
      const x = (e.clientX - rect.left) / rect.width;
      const y = (e.clientY - rect.top) / rect.height;
      const rotY = (x - 0.5) * 14;
      const rotX = (0.5 - y) * 10;
      heroWindow.style.transform =
        `rotateY(${-8 + rotY * 0.3}deg) rotateX(${4 + rotX * 0.3}deg) translateY(0)`;
      heroWindow.style.animation = 'none';
    });
    heroArt.addEventListener('mouseleave', () => {
      heroWindow.style.transform = '';
      heroWindow.style.animation = '';
    });
  }
})();
