import { z } from 'zod';

const directionSchema = z.enum(['up', 'down', 'left', 'right']);

export const clientMessageSchema = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('join_world'),
    name: z.string().trim().min(1).max(24),
    mapId: z.string().min(1).max(80),
    x: z.number().finite(),
    y: z.number().finite(),
    px: z.number().finite().optional(),
    py: z.number().finite().optional(),
    facing: directionSchema.default('down'),
    moving: z.boolean().default(false),
    appearance: z.string().max(80).optional(),
  }).strict(),
  z.object({
    type: z.literal('move'),
    mapId: z.string().min(1).max(80),
    x: z.number().finite(),
    y: z.number().finite(),
    px: z.number().finite().optional(),
    py: z.number().finite().optional(),
    facing: directionSchema,
    moving: z.boolean().optional(),
    seq: z.number().int().nonnegative().optional(),
  }).strict(),
  z.object({ type: z.literal('challenge'), targetId: z.string().uuid() }).strict(),
  z.object({
    type: z.literal('challenge_reply'),
    challengeId: z.string().uuid(),
    accept: z.boolean(),
  }).strict(),
  z.object({
    type: z.literal('battle_message'),
    battleId: z.string().uuid(),
    payload: z.unknown(),
  }).strict(),
  z.object({ type: z.literal('battle_end'), battleId: z.string().uuid() }).strict(),
  z.object({ type: z.literal('ping'), nonce: z.union([z.string(), z.number()]).optional() }).strict(),
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type Direction = z.infer<typeof directionSchema>;

export interface PublicPlayer {
  id: string;
  name: string;
  mapId: string;
  x: number;
  y: number;
  px?: number;
  py?: number;
  facing: Direction;
  moving: boolean;
  appearance?: string;
}

export type ServerMessage = { type: string; [key: string]: unknown };

export function parseClientMessage(value: unknown): ClientMessage {
  return clientMessageSchema.parse(value);
}
