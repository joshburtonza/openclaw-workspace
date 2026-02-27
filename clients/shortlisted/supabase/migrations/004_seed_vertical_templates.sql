-- ============================================================
-- Migration 004: Seed vertical templates
-- Six verticals: teaching, legal, tech, medical, finance, generic
-- teaching preserves the existing SA recruitment logic exactly.
-- ============================================================

INSERT INTO vertical_templates (name, display_name, ai_system_prompt, ai_extraction_schema, gate_rules, scoring_config)
VALUES

-- ============================================================
-- 1. TEACHING (existing SA educator logic, migrated verbatim)
-- ============================================================
(
  'teaching',
  'Teaching & Education',
  'You are an expert South African educator recruiter. Extract candidate details from this CV or email. The candidate has_required_qualification if they have a relevant teaching degree (BEd, PGCE, or equivalent) and are registered or eligible for SACE registration. Evaluate the full document carefully before responding. Return valid JSON only — no prose, no markdown, no code fences.',
  '{
    "candidate_name": "string — full name of the candidate",
    "email_address": "string — primary email address",
    "contact_number": "string — phone or mobile number",
    "current_location_raw": "string — city/province/country as stated",
    "countries_raw": ["array of strings — all countries mentioned in work/study history"],
    "has_required_qualification": "boolean — true if candidate holds a teaching qualification (BEd, PGCE, or equivalent) AND is registered or eligible for SACE registration",
    "years_teaching_experience": "integer — total years of classroom teaching experience (maps to years_experience)",
    "qualification_type": "string — highest teaching qualification (e.g. BEd, PGCE, BA+PGCE)",
    "subject_specialisation": "string — primary teaching subject(s)",
    "university_attended": "string — institution where teaching qualification was obtained",
    "has_sace_registration": "boolean — true if candidate explicitly mentions SACE registration",
    "has_education_degree": "boolean — true if candidate holds a formal education degree",
    "raw_ai_score": "integer 0-100 — overall suitability score for SA teaching role",
    "ai_notes": "string — brief recruiter note on strengths and concerns"
  }',
  '{
    "hard": [
      {
        "field": "has_required_qualification",
        "op": "eq",
        "value": true,
        "reason": "Must have teaching qualification (BEd, PGCE, or equivalent) and SACE eligibility"
      }
    ],
    "soft": [
      {
        "field": "years_experience",
        "op": "lt",
        "value": 2,
        "reason": "Less than 2 years classroom experience"
      }
    ]
  }',
  '{
    "weights": {
      "has_sace_registration": 20,
      "years_experience": 15,
      "subject_specialisation": 10,
      "raw_ai_score": 55
    }
  }'
),

-- ============================================================
-- 2. LEGAL
-- ============================================================
(
  'legal',
  'Legal & Law',
  'You are an expert South African legal recruiter. Extract candidate details from this CV or email. The candidate has_required_qualification if they hold an LLB degree or a BCom Law degree. Admitted attorneys and candidate attorneys are both valid — note the distinction. Evaluate the full document carefully before responding. Return valid JSON only — no prose, no markdown, no code fences.',
  '{
    "candidate_name": "string — full name of the candidate",
    "email_address": "string — primary email address",
    "contact_number": "string — phone or mobile number",
    "has_required_qualification": "boolean — true if candidate holds an LLB or BCom Law degree",
    "years_experience": "integer — total years of post-qualification legal experience",
    "is_admitted_attorney": "boolean — true if candidate is a fully admitted attorney (not merely a candidate attorney)",
    "specialisation_area": "string — primary area of law (e.g. commercial, labour, conveyancing, litigation)",
    "law_society_registration": "string — Law Society or LSSA registration number if mentioned",
    "current_location_raw": "string — city/province/country as stated",
    "raw_ai_score": "integer 0-100 — overall suitability score for a SA legal role",
    "ai_notes": "string — brief recruiter note on strengths and concerns"
  }',
  '{
    "hard": [
      {
        "field": "has_required_qualification",
        "op": "eq",
        "value": true,
        "reason": "Must hold an LLB or BCom Law degree"
      }
    ],
    "soft": [
      {
        "field": "years_experience",
        "op": "lt",
        "value": 1,
        "reason": "Less than 1 year post-qualification legal experience"
      }
    ]
  }',
  '{
    "weights": {
      "is_admitted_attorney": 25,
      "years_experience": 20,
      "raw_ai_score": 55
    }
  }'
),

-- ============================================================
-- 3. TECH (software engineers)
-- ============================================================
(
  'tech',
  'Technology & Software Engineering',
  'You are an expert technology recruiter. Extract candidate details from this CV or email. The candidate has_required_qualification if they hold a relevant technology degree (BSc Computer Science, BEng, BIT, or equivalent) OR have 3 or more years of demonstrated software engineering experience in a professional setting. Evaluate the full document carefully before responding. Return valid JSON only — no prose, no markdown, no code fences.',
  '{
    "candidate_name": "string — full name of the candidate",
    "email_address": "string — primary email address",
    "contact_number": "string — phone or mobile number",
    "has_required_qualification": "boolean — true if candidate holds a relevant tech degree OR has 3+ years professional software engineering experience",
    "years_experience": "integer — total years of professional software engineering experience",
    "primary_stack": ["array of strings — main programming languages, frameworks, and platforms (e.g. React, Node.js, Python, AWS)"],
    "seniority_level": "string — one of: junior, mid, senior, lead, principal, architect",
    "current_location_raw": "string — city/province/country as stated",
    "raw_ai_score": "integer 0-100 — overall suitability score for a software engineering role",
    "ai_notes": "string — brief recruiter note on technical strengths and concerns"
  }',
  '{
    "hard": [
      {
        "field": "has_required_qualification",
        "op": "eq",
        "value": true,
        "reason": "Must hold a relevant technology degree or have 3+ years professional software engineering experience"
      }
    ],
    "soft": [
      {
        "field": "years_experience",
        "op": "lt",
        "value": 2,
        "reason": "Less than 2 years professional experience"
      }
    ]
  }',
  '{
    "weights": {
      "years_experience": 20,
      "seniority_level": 15,
      "raw_ai_score": 65
    }
  }'
),

-- ============================================================
-- 4. MEDICAL
-- ============================================================
(
  'medical',
  'Medical & Healthcare',
  'You are an expert South African healthcare recruiter. Extract candidate details from this CV or email. The candidate has_required_qualification if they are registered with the Health Professions Council of South Africa (HPCSA) or the South African Nursing Council (SANC). Evaluate the full document carefully before responding. Return valid JSON only — no prose, no markdown, no code fences.',
  '{
    "candidate_name": "string — full name of the candidate",
    "email_address": "string — primary email address",
    "contact_number": "string — phone or mobile number",
    "has_required_qualification": "boolean — true if candidate is registered with HPCSA or SANC",
    "years_experience": "integer — total years of post-qualification clinical practice",
    "qualification_type": "string — primary qualification (e.g. MBChB, BPharm, BNurs, BSc Physiotherapy)",
    "specialisation": "string — medical specialisation or nursing category if applicable",
    "hpcsa_registration_number": "string — HPCSA or SANC registration number if mentioned",
    "current_location_raw": "string — city/province/country as stated",
    "raw_ai_score": "integer 0-100 — overall suitability score for a SA healthcare role",
    "ai_notes": "string — brief recruiter note on clinical strengths and concerns"
  }',
  '{
    "hard": [
      {
        "field": "has_required_qualification",
        "op": "eq",
        "value": true,
        "reason": "Must be registered with HPCSA or SANC"
      }
    ],
    "soft": [
      {
        "field": "years_experience",
        "op": "lt",
        "value": 1,
        "reason": "Less than 1 year post-qualification clinical experience"
      }
    ]
  }',
  '{
    "weights": {
      "hpcsa_registration_number": 25,
      "years_experience": 20,
      "raw_ai_score": 55
    }
  }'
),

-- ============================================================
-- 5. FINANCE
-- ============================================================
(
  'finance',
  'Finance & Accounting',
  'You are an expert South African finance recruiter. Extract candidate details from this CV or email. The candidate has_required_qualification if they hold a recognised professional finance qualification: CA(SA), CIMA, ACCA, or a BCom Accounting / BCom Financial Management degree. Evaluate the full document carefully before responding. Return valid JSON only — no prose, no markdown, no code fences.',
  '{
    "candidate_name": "string — full name of the candidate",
    "email_address": "string — primary email address",
    "contact_number": "string — phone or mobile number",
    "has_required_qualification": "boolean — true if candidate holds CA(SA), CIMA, ACCA, or a relevant BCom degree",
    "years_experience": "integer — total years of post-qualification finance or accounting experience",
    "qualification_type": "string — highest finance qualification (e.g. CA(SA), CIMA, ACCA, BCom Accounting)",
    "articles_completed": "boolean — true if candidate has completed SAICA or SAIPA articles",
    "current_location_raw": "string — city/province/country as stated",
    "raw_ai_score": "integer 0-100 — overall suitability score for a SA finance or accounting role",
    "ai_notes": "string — brief recruiter note on strengths and concerns"
  }',
  '{
    "hard": [
      {
        "field": "has_required_qualification",
        "op": "eq",
        "value": true,
        "reason": "Must hold CA(SA), CIMA, ACCA, or a recognised BCom finance degree"
      }
    ],
    "soft": [
      {
        "field": "years_experience",
        "op": "lt",
        "value": 2,
        "reason": "Less than 2 years post-qualification finance experience"
      }
    ]
  }',
  '{
    "weights": {
      "articles_completed": 20,
      "years_experience": 20,
      "raw_ai_score": 60
    }
  }'
),

-- ============================================================
-- 6. GENERIC (no hard gates — always passes if it looks like a CV)
-- ============================================================
(
  'generic',
  'General / Other',
  'You are an expert recruiter. Extract candidate details from this CV or email. This is a general screening — there are no mandatory qualification requirements. Set has_required_qualification to true if the document is a genuine CV or job application (i.e. it represents a real candidate). Set it to false only if the email is clearly not a job application (e.g. spam or an unrelated enquiry). Evaluate the full document carefully before responding. Return valid JSON only — no prose, no markdown, no code fences.',
  '{
    "candidate_name": "string — full name of the candidate",
    "email_address": "string — primary email address",
    "contact_number": "string — phone or mobile number",
    "has_required_qualification": "boolean — true if this is a genuine CV or job application",
    "years_experience": "integer — total years of professional work experience",
    "qualifications_summary": "string — brief summary of educational qualifications",
    "current_location_raw": "string — city/province/country as stated",
    "raw_ai_score": "integer 0-100 — overall suitability score based on the role context",
    "ai_notes": "string — brief recruiter note on candidate background"
  }',
  '{
    "hard": [],
    "soft": []
  }',
  '{
    "weights": {
      "years_experience": 20,
      "raw_ai_score": 80
    }
  }'
);
