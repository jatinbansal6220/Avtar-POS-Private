import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';

await mkdir(new URL('./artifacts/', import.meta.url), { recursive: true });
const context = await chromium.launchPersistentContext(
  new URL('./artifacts/browser-profile/', import.meta.url).pathname.replace(/^\/(\w:)/, '$1'),
  { channel: 'chrome', headless: false, viewport: { width: 1440, height: 900 } },
);
const page = context.pages()[0] ?? await context.newPage();
page.on('pageerror', error => console.error('PAGE ERROR:', error.message));
page.on('console', message => {
  if (message.type() === 'error') console.error('BROWSER:', message.text());
});
await page.goto('http://127.0.0.1:8080', { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(3000);
const accessibility = page.locator('flt-semantics-placeholder');
if (await accessibility.count()) await accessibility.evaluate(element => element.click());
await page.waitForTimeout(1500);
if (await page.getByRole('textbox', { name: 'Backend API address', exact: true }).count()) {
  await page.getByRole('textbox', { name: 'Backend API address', exact: true }).fill('http://127.0.0.1:8000/api');
  await page.getByRole('textbox', { name: 'Email address', exact: true }).fill('preview@avtar.local');
  await page.getByRole('textbox', { name: 'Password', exact: true }).fill('preview');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  try {
    await page.getByText('Floor overview', { exact: true }).waitFor({ timeout: 45000 });
  } catch (error) {
    console.error('Preview login did not reach floor:', error.message);
  }
}
console.log(await page.locator('body').ariaSnapshot());
await page.screenshot({ path: new URL('./artifacts/browser-open.png', import.meta.url).pathname.replace(/^\/(\w:)/, '$1') });
console.log('Browser open at http://127.0.0.1:8080');
await new Promise(resolve => context.on('close', resolve));
