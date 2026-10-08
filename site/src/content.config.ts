import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    // Search-result snippet and og:description. Optional only for drafts:
    // a published post without one would fall back to the site-wide text.
    description: z.string().optional(),
    date: z.coerce.date(),
    tags: z.array(z.string()).default([]),
    lang: z.enum(['zh', 'en']).default('zh'),
    draft: z.boolean().default(false),
  }).refine((d) => d.draft || !!d.description, {
    message: 'published posts need a description',
    path: ['description'],
  }),
});

export const collections = { blog };
