declare module "htmldiff-js" {
  const HtmlDiff: {
    execute(oldText: string, newText: string): string;
  };
  export default HtmlDiff;
}
