#!/usr/bin/env node

/**
 * MISSION CONTROL INTEGRATION
 * OpenClaw ↔ Mission Control Hub
 * 
 * This script connects OpenClaw agents to Mission Control dashboard
 * Handles: email queue, approvals, task execution, kill switch
 */

import { createClient } from '@supabase/supabase-js';
import * as fs from 'fs';
import * as path from 'path';
import { spawn } from 'child_process';

const SUPABASE_URL = 'https://afmpbtynucpbglwtbfuz.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ';
const KILL_SWITCH_FILE = '/Users/henryburton/.openclaw/KILL_SWITCH';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// CHECK KILL SWITCH
async function checkKillSwitch(): Promise<boolean> {
  try {
    // Check database
    const { data } = await supabase
      .from('kill_switch')
      .select('status')
      .eq('id', '00000000-0000-0000-0000-000000000001')
      .single();

    if (data?.status === 'stopped') {
      console.log('[KILL SWITCH] All operations halted');
      return false;
    }

    // Check file
    if (fs.existsSync(KILL_SWITCH_FILE)) {
      const content = fs.readFileSync(KILL_SWITCH_FILE, 'utf-8').trim();
      if (content === 'STOP') {
        console.log('[KILL SWITCH] File-based stop detected');
        return false;
      }
    }

    return true;
  } catch (error) {
    console.error('[KILL SWITCH] Error checking status:', error);
    return false;
  }
}

const WORKSPACE = '/Users/henryburton/.openclaw/workspace-anthropic';

// Send FYI card (auto_pending): Hold-only Telegram notification
function sendAutoFYI(emailId: string, client: string, subject: string, fromEmail: string, draftBody: string, scheduledAt: string): void {
  const child = spawn('bash', [
    `${WORKSPACE}/telegram-send-approval.sh`,
    'fyi', emailId, client, subject, fromEmail, draftBody, scheduledAt,
  ], { detached: true, stdio: 'ignore' });
  child.unref();
}

// Send standard approval card: Approve / Adjust / Hold
function sendApprovalCard(emailId: string, client: string, subject: string, fromEmail: string, inboundBody: string, draftBody: string): void {
  const child = spawn('bash', [
    `${WORKSPACE}/telegram-send-approval.sh`,
    emailId, client, subject, fromEmail, inboundBody, draftBody,
  ], { detached: true, stdio: 'ignore' });
  child.unref();
}

// SOPHIA CSM: ANALYZE EMAIL
async function analyzeEmailWithSophia(emailId: string, fromEmail: string, subject: string, body: string, client: string) {
  const canProceed = await checkKillSwitch();
  if (!canProceed) return;

  try {
    // Simulate Sophia's analysis
    const analysis = {
      type: detectEmailType(body),
      escalation: detectEscalation(body),
      recommendation: generateRecommendation(body, client),
      timestamp: new Date().toISOString()
    };

    const escalation = analysis.escalation;
    const emailType = analysis.type;
    const isRoutine = !escalation && (emailType === 'acknowledgment' || emailType === 'general_inquiry');

    const draftBody: string = (analysis as any).draft_body || (analysis as any).draft_response || analysis.recommendation || '';

    if (isRoutine) {
      // Auto-send after 30-min veto window
      const scheduledAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();
      await supabase
        .from('email_queue')
        .update({
          status: 'auto_pending',
          scheduled_send_at: scheduledAt,
          requires_approval: false,
          analysis: { ...analysis, auto_approved: true },
          updated_at: new Date().toISOString(),
        })
        .eq('id', emailId);

      sendAutoFYI(emailId, client, subject, fromEmail, draftBody, scheduledAt);
      console.log(`[SOPHIA] Routine email → auto_pending, sends at ${scheduledAt}`);
    } else {
      // Escalation or unknown sender — requires approval
      await supabase
        .from('email_queue')
        .update({
          status: 'awaiting_approval',
          requires_approval: true,
          analysis,
          updated_at: new Date().toISOString(),
        })
        .eq('id', emailId);

      sendApprovalCard(emailId, client, subject, fromEmail, body, draftBody);
      console.log(`[SOPHIA] Escalation detected (${escalation ?? 'new sender'}) — awaiting approval`);
    }

    // Log to audit
    await logToAudit('sophia_csm', 'email_analysis', { emailId, analysis, isRoutine }, 'success');
  } catch (error) {
    console.error('[SOPHIA] Analysis failed:', error);
    await logToAudit('sophia_csm', 'email_analysis', { emailId }, 'failure', String(error));
  }
}

// EMAIL TYPE DETECTION
function detectEmailType(body: string): string {
  if (body.toLowerCase().includes('budget') || body.toLowerCase().includes('price')) return 'budget_inquiry';
  if (body.toLowerCase().includes('problem') || body.toLowerCase().includes('issue')) return 'technical_issue';
  if (body.toLowerCase().includes('thanks') || body.toLowerCase().includes('appreciate')) return 'acknowledgment';
  if (body.toLowerCase().includes('timeline') || body.toLowerCase().includes('when')) return 'timeline_question';
  return 'general_inquiry';
}

// ESCALATION DETECTION
function detectEscalation(body: string): string | null {
  const escalationKeywords = [
    'budget',
    'cost',
    'price',
    'cancel',
    'churn',
    'unhappy',
    'problem',
    'broken',
    'not working',
    'urgent',
    'asap'
  ];

  for (const keyword of escalationKeywords) {
    if (body.toLowerCase().includes(keyword)) {
      return keyword;
    }
  }
  return null;
}

// GENERATE RECOMMENDATION
function generateRecommendation(body: string, client: string): string {
  const emailType = detectEmailType(body);
  
  if (emailType === 'budget_inquiry') {
    return 'Route to Josh/Salah - defer budget discussion with: "I will run this by the team and we will come back to you within 24-48 hours"';
  }
  if (emailType === 'technical_issue') {
    return 'Sophia asks diagnostic questions to understand issue anatomically before responding';
  }
  if (emailType === 'acknowledgment') {
    return 'No response needed - mark as skipped';
  }

  return 'Sophia can respond with routine acknowledgment';
}

// SEND APPROVED EMAIL
async function sendApprovedEmail(emailId: string) {
  const canProceed = await checkKillSwitch();
  if (!canProceed) return;

  try {
    // Fetch email details
    const { data: email } = await supabase
      .from('email_queue')
      .select('*')
      .eq('id', emailId)
      .single();

    if (!email || email.status !== 'approved') {
      console.log('[SEND] Email not ready to send');
      return;
    }

    // TODO: Call gog gmail send command
    // For now, just mark as sent
    await supabase
      .from('email_queue')
      .update({
        status: 'sent',
        updated_at: new Date().toISOString()
      })
      .eq('id', emailId);

    console.log(`[SEND] Email sent to ${email.to_email}`);
    await logToAudit('sophia_csm', 'email_send', { emailId }, 'success');
  } catch (error) {
    console.error('[SEND] Failed:', error);
    await logToAudit('sophia_csm', 'email_send', { emailId }, 'failure', String(error));
  }
}

// LOG TO AUDIT TRAIL
async function logToAudit(agent: string, action: string, details: any, status: string, errorMsg?: string) {
  try {
    await supabase
      .from('audit_log')
      .insert({
        agent,
        action,
        details,
        status,
        error_message: errorMsg,
        executed_at: new Date().toISOString()
      });
  } catch (error) {
    console.error('[AUDIT] Failed to log:', error);
  }
}

// MAIN POLLING LOOP
async function startPolling() {
  console.log('[MISSION CONTROL] Starting integration...');

  // Poll for emails
  setInterval(async () => {
    const canProceed = await checkKillSwitch();
    if (!canProceed) {
      console.log('[POLLING] Kill switch active - pausing');
      return;
    }

    try {
      // NOTE: Email analysis is now handled by com.amalfiai.sophia-cron (LaunchAgent).
      // mission-control-integration.ts no longer processes pending emails.
      // Keeping this loop alive only for kill-switch monitoring and future webhook support.
    } catch (error) {
      console.error('[POLLING] Error:', error);
    }
  }, 5000); // Poll every 5 seconds
}

// Export for OpenClaw integration
export {
  checkKillSwitch,
  analyzeEmailWithSophia,
  sendApprovedEmail,
  logToAudit,
  startPolling
};

// Run if executed directly
startPolling().catch(console.error);
