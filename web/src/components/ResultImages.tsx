export function ResultImages({ srcs }: { srcs: string[] }) {
  return (
    <div class="tool-result-images">
      {srcs.map((src, i) => (
        <img
          key={i}
          src={src}
          alt="Tool result image"
          class="tool-result-image"
        />
      ))}
    </div>
  );
}
