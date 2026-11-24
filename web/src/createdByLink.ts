export interface CreatedByLink {
  href: string;
  tid: number;
  title?: string;
}

export function createdByLink(
  task: { creatorTid?: number } | undefined,
  getByTid: (tid: number) => { title?: string } | undefined,
  getTaskHref: (id: string) => string,
): CreatedByLink | undefined {
  const tid = task?.creatorTid;
  if (!tid) return undefined;
  return { href: getTaskHref(String(tid)), tid, title: getByTid(tid)?.title };
}
