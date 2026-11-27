import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

function entrySchema(label: string) {
  return z
    .object({
      title: z.string(),
      // Search-result snippet and og:description. Optional only for drafts:
      // a published entry without one would fall back to the site-wide text.
      description: z.string().optional(),
      date: z.coerce.date(),
      tags: z.array(z.string()).default([]),
      lang: z.enum(['zh', 'en']).default('zh'),
      draft: z.boolean().default(false),
    })
    .refine((d) => d.draft || !!d.description, {
      message: `published ${label} need a description`,
      path: ['description'],
    });
}

const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: entrySchema('posts'),
});

const guides = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/guides' }),
  schema: entrySchema('guides'),
});

export const collections = { blog, guides };
