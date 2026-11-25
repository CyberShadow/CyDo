import type { CreatedByLink } from "../createdByLink";

export function TaskOrigin({ creator }: { creator: CreatedByLink }) {
  return (
    <div class="task-origin">
      <a href={creator.href}>
        ↳{" "}
        {creator.title
          ? `Created by “${creator.title}”`
          : `Created by task ${creator.tid}`}
      </a>
    </div>
  );
}
