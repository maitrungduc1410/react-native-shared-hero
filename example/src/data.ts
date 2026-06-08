export type Photo = {
  id: string;
  uri: string;
  title: string;
  subtitle: string;
  color: string;
};

export const PHOTOS: Photo[] = [
  {
    id: '10',
    uri: 'https://picsum.photos/id/10/800/600',
    title: 'Pine Cathedral',
    subtitle: 'Forests of the Pacific Northwest',
    color: '#1f3a2b',
  },
  {
    id: '1015',
    uri: 'https://picsum.photos/id/1015/800/600',
    title: 'Glacial Bend',
    subtitle: 'Banff National Park, Alberta',
    color: '#1f3550',
  },
  {
    id: '1018',
    uri: 'https://picsum.photos/id/1018/800/600',
    title: 'Summit Light',
    subtitle: 'A morning above the treeline',
    color: '#3a2a1a',
  },
  {
    id: '1025',
    uri: 'https://picsum.photos/id/1025/800/600',
    title: 'The Visitor',
    subtitle: 'A pug, considering you',
    color: '#403a2c',
  },
  {
    id: '1043',
    uri: 'https://picsum.photos/id/1043/800/600',
    title: 'Pacific Shelf',
    subtitle: 'Sea stacks at low tide',
    color: '#2d4451',
  },
  {
    id: '106',
    uri: 'https://picsum.photos/id/106/800/600',
    title: 'Wild Iris',
    subtitle: 'Macro, with morning dew',
    color: '#4a2a4d',
  },
];

export function photoById(id: string): Photo {
  return PHOTOS.find((p) => p.id === id) ?? PHOTOS[0]!;
}
