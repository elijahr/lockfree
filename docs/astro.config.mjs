// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mermaid from 'astro-mermaid';
import starlightImageZoom from 'starlight-image-zoom';

export default defineConfig({
  site: 'https://axiomantic.github.io',
  base: '/lockfree',
  integrations: [
    mermaid(),
    starlight({
      title: 'lockfree',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/axiomantic/lockfree'
        }
      ],
      plugins: [
        starlightImageZoom(),
      ],
      sidebar: [
        {
          label: 'Guides',
          items: [
            { label: 'Quick Start', slug: 'guide/getting-started' },
          ],
        },
        {
          label: 'API Reference',
          items: [
            { autogenerate: { directory: 'api' } }
          ],
        },
      ],
    }),
  ],
});
