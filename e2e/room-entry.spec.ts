import { test, expect } from '@playwright/test';

test('dua browser terpisah dapat membuka alur masuk tanpa berbagi profil lokal',async({browser})=>{
  const contextA=await browser.newContext();
  const contextB=await browser.newContext();
  try{
    const pageA=await contextA.newPage();
    const pageB=await contextB.newPage();
    for(const page of [pageA,pageB]){
      await page.route('**/.well-known/ldr-config',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({url:'https://project.invalid',key:'test-publishable-key'})}));
      await page.goto('/');
      await expect(page.getByRole('heading',{name:/Ruang kecil/i})).toBeVisible();
      await expect(page.getByText('Lanjut sebagai tamu')).toBeVisible();
    }
    await pageA.getByPlaceholder('Contoh: Rara').fill('Pemain A');
    await pageA.getByRole('button',{name:'Pilih avatar 🐱'}).click();
    await expect(pageA.getByRole('button',{name:'Pilih avatar 🐱'})).toHaveClass(/selected/);
    await expect(pageB.getByPlaceholder('Contoh: Rara')).toHaveValue('');
  }finally{
    await contextA.close();await contextB.close();
  }
});

test('UI stays mobile sized and shows the two-seat privacy promise',async({browser})=>{
  const context=await browser.newContext({viewport:{width:390,height:844}});
  try{
    const page=await context.newPage();
    await page.route('**/.well-known/ldr-config',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({url:'https://project.invalid',key:'test-publishable-key'})}));
    await page.goto('/');
    await expect(page.getByText('🔒 khusus 2 pemain')).toBeVisible();
    expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
  }finally{await context.close()}
});
