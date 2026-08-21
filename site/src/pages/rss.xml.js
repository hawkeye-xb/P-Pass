import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';
import { SITE_TITLE, SITE_DESCRIPTION } from '../consts';

export async function GET(context) {
  const posts = (
    await getCollection('blog', ({ data }) => !data.draft && data.lang === 'zh')
  ).sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());
  return rss({
    title: SITE_TITLE.zh,
    description: SITE_DESCRIPTION.zh,
    site: context.site,
    items: posts.map((post) => ({
      title: post.data.title,
      pubDate: post.data.date,
      description: post.body.slice(0, 200),
      link: `/zh/blog/${post.id}/`,
    })),
  });
}
