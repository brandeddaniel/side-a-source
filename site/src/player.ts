import { analytics } from './analytics';
import * as THREE from 'three';
import environmentSize from './environment.json';
import environmentURL from './studio.env?url';
import metadata from './generated/model.json';
import meshURL from './generated/discman.mesh?url';
import { createPlayerFraming } from './framing.mjs';

export async function startPlayer() {
  const canvas = document.querySelector<HTMLCanvasElement>('#player')!;
  const stage = document.querySelector<HTMLDivElement>('#stage')!;
  const liveStatus = document.querySelector('#preview-status')!;
  const hint = document.querySelector('#model-hint')!;
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const [response, environmentResponse] = await Promise.all([fetch(meshURL), fetch(environmentURL)]);
  if (!response.ok) throw new Error('Model unavailable');
  if (!response.body) throw new Error('Model unavailable');
  const data = await new Response(response.body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  const scene = new THREE.Scene();
  if (!environmentResponse.ok || !environmentResponse.body) throw new Error('Lighting unavailable');
  const environmentData = await new Response(environmentResponse.body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  // Precomputed RoomEnvironment PMREM avoids rendering and blurring its cube maps on every visit.
  const environment = new THREE.DataTexture(new Uint16Array(environmentData), environmentSize.width, environmentSize.height, THREE.RGBAFormat, THREE.HalfFloatType);
  environment.mapping = THREE.CubeUVReflectionMapping;
  environment.minFilter = THREE.LinearFilter;
  environment.magFilter = THREE.LinearFilter;
  environment.needsUpdate = true;
  scene.environment = environment;
  scene.environmentIntensity = 1.0;
  scene.add(new THREE.HemisphereLight(0xffffff, 0x61696c, 0.8));
  const key = new THREE.DirectionalLight(0xffffff, 2.0);
  key.position.set(-3, 8, 5);
  scene.add(key);
  const camera = new THREE.OrthographicCamera(-3, 3, 2, -2, 0.1, 100);
  camera.position.set(0.55, 8.8, 5.3);
  camera.lookAt(0, 0.22, 0);
  const player = new THREE.Group();
  player.rotation.y = -0.12;
  scene.add(player);
  const hinge = new THREE.Group();
  hinge.position.set(0, 0.45, -2.05);
  player.add(hinge);
  const disc = new THREE.Group();
  player.add(disc);
  const controls: THREE.Mesh[] = [];
  for (const item of metadata) {
    const geometry = new THREE.BufferGeometry();
    const quantized = new Uint16Array(data, item.offset, item.count * 3);
    const positions = Float32Array.from(quantized, (value, i) => item.min[i % 3] + value / 65535 * (item.max[i % 3] - item.min[i % 3]));
    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.BufferAttribute(new Int16Array(data, item.normalOffset, item.count * 3), 3, true));
    geometry.setIndex(new THREE.BufferAttribute(item.wide ? new Uint32Array(data, item.indexOffset, item.indexCount) : new Uint16Array(data, item.indexOffset, item.indexCount), 1));
    const material = new THREE.MeshStandardMaterial({ color: new THREE.Color().setRGB(item.color[0], item.color[1], item.color[2], THREE.SRGBColorSpace), metalness: item.metallic, roughness: item.roughness });
    const mesh = new THREE.Mesh(geometry, material);
    mesh.name = item.name;
    mesh.userData.action = item.action;
    if (item.lid) { mesh.position.set(0, -0.45, 2.05); hinge.add(mesh); }
    else if (item.name === 'Disc' || item.name.startsWith('Disc groove') || item.name === 'Disc label') { mesh.userData.action = 'spin'; disc.add(mesh); }
    else player.add(mesh);
    controls.push(mesh);
    // Yield between batches so setup/download controls remain responsive during geometry creation.
    if (controls.length % 10 === 0) await new Promise<void>(resolve => setTimeout(resolve, 0));
  }
  const lcdCanvas = document.createElement('canvas');
  lcdCanvas.width = 820; lcdCanvas.height = 295;
  const ctx = lcdCanvas.getContext('2d')!;
  const lcdTexture = new THREE.CanvasTexture(lcdCanvas);
  lcdTexture.colorSpace = THREE.SRGBColorSpace;
  const lcd = new THREE.Mesh(new THREE.PlaneGeometry(1.64, 0.59), new THREE.MeshBasicMaterial({ map: lcdTexture }));
  lcd.rotation.x = -Math.PI / 2;
  lcd.position.set(0, 0.299, 2.71);
  lcd.userData.action = 'next';
  hinge.add(lcd);
  controls.push(lcd);
  const fitPlayer = createPlayerFraming(camera, player);
  const accounts = [{ name: 'PERSONAL', provider: 'CLAUDE' }, { name: 'STUDIO', provider: 'CLAUDE' }, { name: 'SIDE PROJECT', provider: 'CODEX' }];
  let track = 0, open = false, playing = false, auto = false, held = false, sideB = false, repeatOne = false;
  let holdTimer = 0, heldLong = false;
  let targetRotation = -0.12, frame = 0, previousTime = 0;
  let down: { x: number; y: number; rotation: number } | null = null;
  const ray = new THREE.Raycaster();
  const pointer = new THREE.Vector2();
  function lcdUpdate() {
    ctx.fillStyle = '#a6b887'; ctx.fillRect(0, 0, 820, 295);
    ctx.fillStyle = '#2c412b';
    ctx.font = '24px monospace';
    ctx.fillText(`${sideB ? 'BONUS' : accounts[track].provider}    ${sideB ? 'SIDE B' : auto ? 'AUTO' : 'SIDE A'}`, 40, 49);
    ctx.font = 'bold 60px monospace'; ctx.fillText(sideB ? 'HIDDEN TRACK' : accounts[track].name, 40, 143);
    ctx.font = '23px monospace'; ctx.fillText(`${held ? 'HOLD' : playing ? 'PLAY' : 'READY'}${repeatOne ? '  REPEAT 1' : '         '}              0${track + 1} / 03`, 40, 241);
    lcdTexture.needsUpdate = true;
    liveStatus.textContent = `Preview account: ${accounts[track].name}, ${accounts[track].provider}. ${playing ? 'Playing' : 'Ready'}. ${open ? 'Lid open.' : ''}`;
  }
  function schedule() { if (!frame && !document.hidden) frame = requestAnimationFrame(render); }
  function resize() {
    renderer.setSize(stage.clientWidth, stage.clientHeight, false);
    schedule();
  }
  function render(time: number) {
    frame = 0;
    const delta = Math.min((time - (previousTime || time)) / 1000, 0.05);
    previousTime = time;
    const targetLid = open ? -1.12 : 0;
    const ease = reducedMotion.matches ? 1 : 1 - Math.exp(-delta * 14);
    hinge.rotation.x += (targetLid - hinge.rotation.x) * ease;
    player.rotation.y += (targetRotation - player.rotation.y) * ease;
    if (open && playing && !reducedMotion.matches) disc.rotation.y += delta * 1.8;
    fitPlayer(stage.clientWidth / stage.clientHeight);
    renderer.render(scene, camera);
    if (Math.abs(targetLid - hinge.rotation.x) > 0.0001 || Math.abs(targetRotation - player.rotation.y) > 0.0001 || (open && playing && !reducedMotion.matches)) schedule();
  }
  function activate(action: string | undefined) {
    if (held && action !== 'hold' && action !== 'open') return;
    switch (action) {
      case 'open': open = !open; break;
      case 'next': track = (track + 1) % accounts.length; break;
      case 'previous': track = (track + accounts.length - 1) % accounts.length; break;
      case 'play': playing = !playing; break;
      case 'spin': if (!open) return; playing = !playing; break;
      case 'stop': playing = false; break;
      case 'mode': auto = !auto; break;
      case 'hold': held = !held; break;
      default: return;
    }
    analytics.capture('demo_interacted', { action });
    hint.textContent = open ? 'A little room for every account.' : 'Go on. Press a button.';
    lcdUpdate(); schedule();
  }
  function hit(event: PointerEvent) {
    const rect = canvas.getBoundingClientRect();
    pointer.set((event.clientX - rect.left) / rect.width * 2 - 1, -(event.clientY - rect.top) / rect.height * 2 + 1);
    ray.setFromCamera(pointer, camera);
    return ray.intersectObjects(controls, false)[0]?.object;
  }
  canvas.addEventListener('pointerdown', event => {
    const target = event.button === 0 ? hit(event) : undefined;
    if (!target) return;
    down = { x: event.clientX, y: event.clientY, rotation: targetRotation };
    canvas.setPointerCapture(event.pointerId);
    // Easter egg: hold play for two seconds to toggle repeat-one.
    heldLong = false;
    if (target.userData.action === 'play') holdTimer = window.setTimeout(() => { heldLong = true; repeatOne = !repeatOne; lcdUpdate(); schedule(); }, 2000);
  });
  canvas.addEventListener('pointermove', event => {
    if (down) { targetRotation = THREE.MathUtils.clamp(down.rotation + (event.clientX - down.x) * 0.004, -0.65, 0.65); schedule(); }
    else canvas.style.cursor = hit(event)?.userData.action ? 'pointer' : hit(event) ? 'grab' : 'default';
  });
  canvas.addEventListener('pointerup', event => {
    clearTimeout(holdTimer);
    if (down && !heldLong && Math.hypot(event.clientX - down.x, event.clientY - down.y) < 7) activate(hit(event)?.userData.action);
    down = null;
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
  });
  canvas.addEventListener('pointercancel', () => { clearTimeout(holdTimer); down = null; });
  // Easter egg: the Konami code anywhere on the page flips the player to Side B.
  const code = ['ArrowUp', 'ArrowUp', 'ArrowDown', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ArrowLeft', 'ArrowRight', 'b', 'a'];
  let progress = 0;
  addEventListener('keydown', event => {
    const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
    // Extra ups keep the first two; any other miss restarts.
    progress = key === code[progress] ? progress + 1 : key === 'ArrowUp' ? (progress === 2 ? 2 : 1) : 0;
    if (progress < code.length) return;
    progress = 0; sideB = !sideB; open = sideB; playing = sideB; held = false;
    lcdUpdate(); schedule();
  });
  addEventListener('sidea:shuffle', () => {
    if (held) return;
    const steps = reducedMotion.matches ? 1 : 7;
    for (let i = 1; i <= steps; i++) setTimeout(() => { track = Math.floor(Math.random() * accounts.length); lcdUpdate(); schedule(); }, i * 110);
  });
  canvas.addEventListener('keydown', event => {
    const action = { ArrowLeft: 'previous', ArrowRight: 'next', Enter: 'open', ' ': 'play', Escape: 'stop' }[event.key];
    if (action) { event.preventDefault(); activate(action); }
  });
  canvas.addEventListener('webglcontextlost', event => { event.preventDefault(); if (frame) cancelAnimationFrame(frame); frame = 0; stage.classList.remove('ready'); });
  canvas.addEventListener('webglcontextrestored', () => { stage.classList.add('ready'); schedule(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden && frame) { cancelAnimationFrame(frame); frame = 0; } else { previousTime = 0; schedule(); } });
  reducedMotion.addEventListener('change', schedule);
  new ResizeObserver(resize).observe(stage);
  await renderer.compileAsync(scene, camera);
  lcdUpdate(); resize();
  // Reveal only after a real frame exists, so the poster crossfades into an identical image.
  await new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
  stage.classList.add('ready');
  // Used by tools/bake-poster to render the poster from this exact scene and framing.
  return { renderer, scene, camera, fitPlayer };
}
