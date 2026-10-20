const demo = document.querySelector('.demo');
const messages = {original: '从完整画面，找到你的主角。', focus: '镜头聚焦，让主角留在画面中央。', privacy: '保护其他人物，保留主角的精彩。'};
document.querySelectorAll('[data-mode]').forEach(button => {
  button.addEventListener('click', () => {
    demo.dataset.state = button.dataset.mode;
    document.querySelectorAll('[data-mode]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.getElementById('demo-status').textContent = messages[button.dataset.mode];
  });
});
const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
const pointer = window.matchMedia('(hover: hover) and (pointer: fine)');
document.querySelectorAll('.magnet, .spotlight').forEach(element => {
  element.addEventListener('pointermove', event => {
    if (motion.matches || !pointer.matches) return;
    const box = element.getBoundingClientRect();
    if (element.classList.contains('magnet')) {
      element.style.transform = `translate(${(event.clientX - box.left - box.width / 2) * .12}px, ${(event.clientY - box.top - box.height / 2) * .18}px)`;
    } else {
      element.style.setProperty('--x', `${event.clientX - box.left}px`);
      element.style.setProperty('--y', `${event.clientY - box.top}px`);
    }
  });
  element.addEventListener('pointerleave', () => { element.style.transform = ''; });
});
