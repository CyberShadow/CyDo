// Recursive unknown-field extraction using Zod schema introspection.
//
// Walks raw data alongside a Zod schema definition, collecting every field
// that is not declared in the schema at any nesting level.

import {
  type ZodTypeAny,
  ZodObject,
  ZodArray,
  ZodDiscriminatedUnion,
  ZodUnion,
  ZodOptional,
  ZodNullable,
  ZodRecord,
  ZodDefault,
} from "zod";

export interface ExtraField {
  path: string; // e.g. "", "message.usage", "message.content[2]"
  key: string; // the unknown field name
  value: unknown; // the unknown field value
}

/** Extract all unknown fields from `data` relative to `schema`, at every nesting level. */
export function extractExtras(
  data: unknown,
  schema: ZodTypeAny,
  path: string = "",
): ExtraField[] {
  const extras: ExtraField[] = [];
  collectExtras(data, schema, path, extras);
  return extras;
}

function collectExtras(
  data: unknown,
  schema: ZodTypeAny,
  path: string,
  out: ExtraField[],
): void {
  const inner = unwrap(schema);

  if (inner instanceof ZodObject) {
    collectFromObject(data, inner, path, out);
  } else if (inner instanceof ZodArray) {
    collectFromArray(data, inner, path, out);
  } else if (inner instanceof ZodDiscriminatedUnion) {
    collectFromDiscriminatedUnion(data, inner, path, out);
  } else if (inner instanceof ZodUnion) {
    collectFromUnion(data, inner, path, out);
  }
  // ZodRecord: arbitrary keys expected — not extras.
  // Primitives (ZodString, ZodNumber, ZodBoolean, ZodLiteral, ZodUnknown, etc.): leaf nodes.
}

/** Strip ZodOptional / ZodNullable / ZodDefault wrappers. */
function unwrap(schema: ZodTypeAny): ZodTypeAny {
  if (schema instanceof ZodOptional || schema instanceof ZodNullable) {
    return unwrap(schema.unwrap() as ZodTypeAny);
  }
  if (schema instanceof ZodDefault) {
    return unwrap((schema._def as any).innerType as ZodTypeAny);
  }
  return schema;
}

function collectFromObject(
  data: unknown,
  schema: ZodObject<any>,
  path: string,
  out: ExtraField[],
): void {
  if (data === null || data === undefined || typeof data !== "object") return;
  const obj = data as Record<string, unknown>;
  const shape = schema.shape as Record<string, ZodTypeAny>;
  const knownKeys = new Set(Object.keys(shape));

  // Report unknown keys
  for (const key of Object.keys(obj)) {
    if (!knownKeys.has(key)) {
      out.push({ path, key, value: obj[key] });
    }
  }

  // Recurse into known keys
  for (const [key, subSchema] of Object.entries(shape)) {
    if (key in obj && obj[key] !== undefined && obj[key] !== null) {
      collectExtras(obj[key], subSchema, path ? `${path}.${key}` : key, out);
    }
  }
}

function collectFromArray(
  data: unknown,
  schema: ZodArray<any>,
  path: string,
  out: ExtraField[],
): void {
  if (!Array.isArray(data)) return;
  const elementSchema = schema.element;
  for (let i = 0; i < data.length; i++) {
    collectExtras(data[i], elementSchema, `${path}[${i}]`, out);
  }
}

function collectFromDiscriminatedUnion(
  data: unknown,
  schema: ZodDiscriminatedUnion<any, any>,
  path: string,
  out: ExtraField[],
): void {
  if (data === null || data === undefined || typeof data !== "object") return;
  const obj = data as Record<string, unknown>;
  const discriminator = (schema._def as any).discriminator as string;
  const discValue = obj[discriminator];

  // Find matching variant from options array
  const options = schema.options as ZodObject<any>[];
  const matchingSchema = options.find((opt) => {
    const lit = opt.shape[discriminator];
    if (!lit) return false;
    const def = lit._def as any;
    // Zod v4: ZodLiteral uses _def.values (array), not _def.value
    const values: unknown[] =
      def?.values ?? (def?.value !== undefined ? [def.value] : []);
    return values.includes(discValue);
  });

  if (matchingSchema) {
    collectExtras(data, matchingSchema, path, out);
  } else {
    // Unknown variant — report the whole object so it's visible
    out.push({
      path,
      key: `(unknown ${discriminator}=${JSON.stringify(discValue)})`,
      value: data,
    });
  }
}

function collectFromUnion(
  data: unknown,
  schema: ZodUnion<any>,
  path: string,
  out: ExtraField[],
): void {
  // Non-discriminated union: try each option, recurse into the first that parses.
  const options = schema.options as ZodTypeAny[];
  for (const option of options) {
    const result = option.safeParse(data);
    if (result.success) {
      collectExtras(data, option, path, out);
      return;
    }
  }
}
