import './style.css';
import './how.css';
import { analytics } from './analytics';

analytics.capture('$pageview');

// Easter egg: clicking the handwritten note underlines it, the way you would on paper.
const note = document.querySelector<HTMLElement>('.note-mark');
const mark = () => note?.setAttribute('aria-pressed', String(note.classList.toggle('marked')));
note?.addEventListener('click', mark);
note?.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); mark(); } });
