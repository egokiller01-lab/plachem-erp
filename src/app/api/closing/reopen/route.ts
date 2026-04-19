import { NextResponse } from 'next/server';
import { supabase } from '@/lib/supabase';

export async function POST(request: Request) {
  try {
    const body = await request.json();
    const { year, month, reason } = body;

    if (!year || !month || !reason) {
      return NextResponse.json({ error: 'Year, month, and reason are required' }, { status: 400 });
    }

    if (reason.length < 10) {
      return NextResponse.json({ error: 'Reason must be at least 10 characters long' }, { status: 400 });
    }

    // const { data: userData, error: userError } = await supabase.auth.getUser();
    // if (userError || !userData?.user) return NextResponse.json({ error: 'Unauthorized: User not found' }, { status: 401 });
    // const role = userData.user.user_metadata?.role;
    // const email = userData.user.email;
    // const isAdmin = role === 'admin' || email === 'plachem2020@naver.com' || email === 'dol1224@hanmail.net';
    // if (!isAdmin) return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
    const userId = '00000000-0000-0000-0000-000000000000';

    const { data, error } = await supabase.rpc('reopen_monthly_closing', {
      p_year: year,
      p_month: month,
      p_reason: reason,
      p_user_uuid: userId
    });

    if (error) {
      console.error('Reopen RPC error:', error);
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    if (data && data.success === false) {
      return NextResponse.json({ error: data.message }, { status: 400 });
    }

    return NextResponse.json({ data }, { status: 200 });

  } catch (err: any) {
    return NextResponse.json({ error: err.message }, { status: 500 });
  }
}
